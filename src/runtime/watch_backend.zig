//! Cross-platform file-system watcher used by the `--watch` loop.
//!
//! The default polling loop (sleep 100ms, stat all watched paths) burns
//! ~10 cycles per second per watched file even when the user isn't doing
//! anything, and only notices changes within poll-tick latency. The
//! native backends here use the OS event source so the watcher blocks
//! until something actually moves on disk:
//!
//! - Linux: `inotify`. Watches the *directory* containing each tracked
//!   file (basename filter on each event) so editor save-rename flows
//!   like vim's `:w` are still observable, and a single inotify watch
//!   serves every job whose entry lives in that directory.
//! - macOS / *BSD: `kqueue` with one `EVFILT_VNODE` registration per
//!   tracked file fd.
//! - Windows: `ReadDirectoryChangesW` with overlapped I/O per directory
//!   plus an APC-style completion handler.
//! - Other targets (haiku, wasi, ...): fall back to the previous mtime
//!   polling loop. Behavior is identical to the pre-native watcher;
//!   this just keeps a uniform abstraction so the `runWatchLoop` body
//!   doesn't have to branch on OS.

const std = @import("std");
const builtin = @import("builtin");
const zsass_io = @import("io.zig");

/// Public watcher facade. The OS-specific impl is selected at comptime
/// via `Impl`. All methods forward to `impl` so callers never see
/// platform-specific types.
pub const WatchBackend = struct {
    impl: Impl,

    pub const Impl = switch (builtin.os.tag) {
        .linux => LinuxInotify,
        .macos, .freebsd, .netbsd, .openbsd, .dragonfly => DarwinKqueue,
        .windows => WindowsRdcw,
        else => Polling,
    };

    /// True when the active backend uses an OS event source rather than
    /// mtime polling. Surfaces to docs / `--info` so users on supported
    /// targets can confirm they're getting the fast path.
    pub const native_events: bool = switch (builtin.os.tag) {
        .linux, .macos, .freebsd, .netbsd, .openbsd, .dragonfly, .windows => true,
        else => false,
    };

    pub fn init(allocator: std.mem.Allocator) !WatchBackend {
        return .{ .impl = try Impl.init(allocator) };
    }

    pub fn deinit(self: *WatchBackend, allocator: std.mem.Allocator) void {
        self.impl.deinit(allocator);
    }

    /// Begin watching `path` and bind any future change to `job_index`.
    /// Multiple paths may map to the same `job_index`; the same path
    /// may be added under different indices (a shared `_partial.scss`
    /// imported by several entries dirties every dependent). Re-adding
    /// an already-known (path, job) pair is a cheap no-op.
    pub fn addWatchedFile(
        self: *WatchBackend,
        allocator: std.mem.Allocator,
        path: []const u8,
        job_index: u32,
    ) !void {
        try self.impl.addWatchedFile(allocator, path, job_index);
    }

    /// Drop every registered watch. The watch loop calls this between
    /// rebuilds before re-collecting because a recompile can add new
    /// imports or drop removed ones; clearing avoids leaking stale
    /// inotify watches and double-registering kqueue fds.
    pub fn clearWatches(self: *WatchBackend, allocator: std.mem.Allocator) void {
        self.impl.clearWatches(allocator);
    }

    /// Block up to `timeout_ms` waiting for any registered path to
    /// change. On wake-up sets `out_dirty[i] = true` for each affected
    /// job index and returns whether at least one bit flipped. A pure
    /// timeout wake (nothing changed) returns false without touching
    /// `out_dirty`.
    pub fn waitForChange(
        self: *WatchBackend,
        timeout_ms: u32,
        out_dirty: []bool,
    ) !bool {
        return self.impl.waitForChange(timeout_ms, out_dirty);
    }
};

// =============================================================================
// Shared per-file -> job_index mapping. Used by every backend that needs
// to map a watched path back to the job(s) that care about it. Keeping
// the data structures here means we only own the path/basename
// allocations once even when several backends compile in.
// =============================================================================

const FileBinding = struct {
    /// Owned slice. For Linux this is the basename within the watched
    /// directory; for kqueue/Windows it is the full path the caller
    /// supplied (never inspected once the watch is registered, but kept
    /// for the de-dup check in `addWatchedFile`).
    name: []u8,
    job_index: u32,
};

fn bindingsHas(list: []const FileBinding, name: []const u8, job_index: u32) bool {
    for (list) |b| {
        if (b.job_index == job_index and std.mem.eql(u8, b.name, name)) return true;
    }
    return false;
}

fn freeBindings(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(FileBinding)) void {
    for (list.items) |b| allocator.free(b.name);
    list.deinit(allocator);
}

fn splitDirAndBasename(path: []const u8) struct { dir: []const u8, base: []const u8 } {
    return .{
        .dir = std.fs.path.dirname(path) orelse ".",
        .base = std.fs.path.basename(path),
    };
}

fn sleepIgnoringCancel(timeout_ms: u32) void {
    const dur = std.Io.Duration.fromMilliseconds(@intCast(timeout_ms));
    zsass_io.io.sleep(dur, .awake) catch |err| switch (err) {
        // The watch loop runs again on the next tick, so a missed
        // sleep is not fatal -- log at debug level and fall through.
        error.Canceled => std.log.debug("watch_backend: sleep canceled", .{}),
    };
}

// =============================================================================
// Linux inotify backend.
//
// Watches the directory of each tracked file with a single inotify
// watch per directory; files within that directory are tracked by
// basename in `bindings`. The fd is opened NONBLOCK so `waitForChange`
// can `poll()` with a timeout and drain everything available with
// `read()` without spinning.
// =============================================================================

const LinuxInotify = struct {
    fd: std.posix.fd_t,
    /// `wd` (returned by `inotify_add_watch`) -> directory state.
    dirs: std.AutoHashMapUnmanaged(i32, DirState) = .empty,
    /// canonical directory path -> wd, for de-duplicating watch creation.
    dir_lookup: std.StringHashMapUnmanaged(i32) = .empty,

    const DirState = struct {
        /// Owned canonical directory path; also used as the key in
        /// `dir_lookup`, so don't free it twice on tear-down.
        dir_path: []u8,
        bindings: std.ArrayListUnmanaged(FileBinding) = .empty,
    };

    pub fn init(_: std.mem.Allocator) !LinuxInotify {
        const flags = std.os.linux.IN.NONBLOCK | std.os.linux.IN.CLOEXEC;
        const rc = std.os.linux.inotify_init1(flags);
        const err = std.posix.errno(rc);
        if (err != .SUCCESS) return std.posix.unexpectedErrno(err);
        return .{ .fd = @intCast(rc) };
    }

    pub fn deinit(self: *LinuxInotify, allocator: std.mem.Allocator) void {
        self.clearWatches(allocator);
        _ = std.os.linux.close(self.fd);
    }

    pub fn clearWatches(self: *LinuxInotify, allocator: std.mem.Allocator) void {
        var it = self.dirs.iterator();
        while (it.next()) |entry| {
            _ = std.os.linux.inotify_rm_watch(self.fd, entry.key_ptr.*);
            freeBindings(allocator, &entry.value_ptr.bindings);
            allocator.free(entry.value_ptr.dir_path);
        }
        // Reuse the underlying buckets across rebuilds; only the entry
        // count resets so the next batch of `addWatchedFile` calls can
        // reuse the existing capacity.
        self.dirs.clearRetainingCapacity();
        self.dir_lookup.clearRetainingCapacity();
    }

    pub fn addWatchedFile(
        self: *LinuxInotify,
        allocator: std.mem.Allocator,
        path: []const u8,
        job_index: u32,
    ) !void {
        const split = splitDirAndBasename(path);

        if (self.dir_lookup.get(split.dir)) |wd| {
            const dir_state = self.dirs.getPtr(wd) orelse return;
            if (bindingsHas(dir_state.bindings.items, split.base, job_index)) return;
            const base_dup = try allocator.dupe(u8, split.base);
            errdefer allocator.free(base_dup);
            try dir_state.bindings.append(allocator, .{ .name = base_dup, .job_index = job_index });
            return;
        }

        // First time we see this directory: register a new inotify watch.
        const dir_z = try allocator.dupeZ(u8, split.dir);
        defer allocator.free(dir_z);

        const mask: u32 = std.os.linux.IN.MODIFY | std.os.linux.IN.CLOSE_WRITE |
            std.os.linux.IN.CREATE | std.os.linux.IN.DELETE |
            std.os.linux.IN.MOVED_FROM | std.os.linux.IN.MOVED_TO;
        const rc = std.os.linux.inotify_add_watch(self.fd, dir_z.ptr, mask);
        const err = std.posix.errno(rc);
        if (err != .SUCCESS) return std.posix.unexpectedErrno(err);
        const wd: i32 = @intCast(@as(isize, @bitCast(rc)));

        const dir_dup = try allocator.dupe(u8, split.dir);
        errdefer allocator.free(dir_dup);
        const base_dup = try allocator.dupe(u8, split.base);
        errdefer allocator.free(base_dup);

        var dir_state: DirState = .{ .dir_path = dir_dup };
        try dir_state.bindings.append(allocator, .{ .name = base_dup, .job_index = job_index });
        errdefer freeBindings(allocator, &dir_state.bindings);

        try self.dirs.put(allocator, wd, dir_state);
        // `dir_dup` is the key in `dir_lookup` *and* the value in
        // `dirs[wd].dir_path`; both views share the same allocation, so
        // teardown only frees it once via the `dirs` iterator.
        try self.dir_lookup.put(allocator, dir_dup, wd);
    }

    pub fn waitForChange(
        self: *LinuxInotify,
        timeout_ms: u32,
        out_dirty: []bool,
    ) !bool {
        var pfd = [_]std.posix.pollfd{.{
            .fd = self.fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = try std.posix.poll(&pfd, @as(i32, @intCast(timeout_ms)));
        if (ready == 0) return false;

        var buf: [4096]u8 align(@alignOf(std.os.linux.inotify_event)) = undefined;
        var any = false;
        while (true) {
            const n = std.posix.read(self.fd, &buf) catch |err| switch (err) {
                error.WouldBlock => break,
                else => |e| return e,
            };
            if (n == 0) break;

            var i: usize = 0;
            while (i < n) {
                const ev: *const std.os.linux.inotify_event = @ptrCast(@alignCast(&buf[i]));
                const name_slice = if (ev.len > 0) blk: {
                    const name_start = i + @sizeOf(std.os.linux.inotify_event);
                    const raw = buf[name_start .. name_start + ev.len];
                    break :blk std.mem.sliceTo(raw, 0);
                } else "";

                if (self.dirs.getPtr(ev.wd)) |dir_state| {
                    for (dir_state.bindings.items) |fb| {
                        if (!std.mem.eql(u8, fb.name, name_slice)) continue;
                        if (fb.job_index >= out_dirty.len) continue;
                        out_dirty[fb.job_index] = true;
                        any = true;
                    }
                }

                i += @sizeOf(std.os.linux.inotify_event) + ev.len;
            }
        }
        return any;
    }
};

// =============================================================================
// macOS / *BSD kqueue backend.
//
// kqueue lacks a clean directory-event model that mirrors inotify, so we
// register one `EVFILT_VNODE` per tracked file fd. That matches what
// `std.Build.Watch` does on Darwin. Editor swap-rename flows do
// trigger NOTE_RENAME / NOTE_DELETE so the change still gets reported,
// after which `clearWatches` + the next compile pass reopen fresh fds
// against the new inode.
// =============================================================================

const DarwinKqueue = struct {
    kq: std.posix.fd_t,
    /// One entry per tracked file fd. The fd doubles as the kevent
    /// `ident`, so the lookup on event delivery is a simple linear scan
    /// of `entries` (lengths in practice are O(jobs * deps), well under
    /// what a hash map would justify).
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    const Entry = struct {
        fd: std.posix.fd_t,
        path: []u8,
        job_index: u32,
    };

    pub fn init(_: std.mem.Allocator) !DarwinKqueue {
        const rc = std.c.kqueue();
        if (rc < 0) return error.Unexpected;
        return .{ .kq = rc };
    }

    pub fn deinit(self: *DarwinKqueue, allocator: std.mem.Allocator) void {
        self.clearWatches(allocator);
        _ = std.c.close(self.kq);
    }

    pub fn clearWatches(self: *DarwinKqueue, allocator: std.mem.Allocator) void {
        for (self.entries.items) |e| {
            _ = std.c.close(e.fd);
            allocator.free(e.path);
        }
        self.entries.clearAndFree(allocator);
    }

    pub fn addWatchedFile(
        self: *DarwinKqueue,
        allocator: std.mem.Allocator,
        path: []const u8,
        job_index: u32,
    ) !void {
        for (self.entries.items) |e| {
            if (e.job_index == job_index and std.mem.eql(u8, e.path, path)) return;
        }

        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);

        const fd = std.posix.openatZ(std.posix.AT.FDCWD, path_z, .{
            .ACCMODE = .RDONLY,
            .CLOEXEC = true,
            .NONBLOCK = true,
        }, 0) catch |err| switch (err) {
            error.FileNotFound => return, // silently skip; next collect pass will retry
            else => |e| return e,
        };
        errdefer _ = std.c.close(fd);

        const path_dup = try allocator.dupe(u8, path);
        errdefer allocator.free(path_dup);

        const note: u32 = std.c.NOTE.WRITE | std.c.NOTE.DELETE |
            std.c.NOTE.RENAME | std.c.NOTE.EXTEND | std.c.NOTE.ATTRIB;
        const changes = [_]std.posix.Kevent{.{
            .ident = @intCast(fd),
            .filter = std.c.EVFILT.VNODE,
            .flags = std.c.EV.ADD | std.c.EV.CLEAR | std.c.EV.ENABLE,
            .fflags = note,
            .data = 0,
            .udata = job_index,
        }};
        // SAFETY: nevents = 0 means kevent never reads from the
        // eventlist pointer; passing `undefined` is the canonical way
        // to call kevent in pure-registration mode.
        const reg_rc = std.c.kevent(self.kq, &changes, 1, undefined, 0, null);
        if (reg_rc < 0) return error.Unexpected;

        try self.entries.append(allocator, .{
            .fd = fd,
            .path = path_dup,
            .job_index = job_index,
        });
    }

    pub fn waitForChange(
        self: *DarwinKqueue,
        timeout_ms: u32,
        out_dirty: []bool,
    ) !bool {
        var events: [16]std.posix.Kevent = undefined;
        const ts = std.posix.timespec{
            .sec = @intCast(timeout_ms / 1000),
            .nsec = @intCast((timeout_ms % 1000) * std.time.ns_per_ms),
        };
        // SAFETY: nchanges = 0 means kevent never reads from the
        // changelist pointer; passing `undefined` is the canonical
        // way to call kevent in pure-wait mode.
        const rc = std.c.kevent(self.kq, undefined, 0, &events, events.len, &ts);
        if (rc < 0) return error.Unexpected;
        if (rc == 0) return false;

        var any = false;
        for (events[0..@intCast(rc)]) |ev| {
            const idx: u32 = @intCast(ev.udata);
            if (idx >= out_dirty.len) continue;
            out_dirty[idx] = true;
            any = true;
        }
        return any;
    }
};

// =============================================================================
// Windows ReadDirectoryChangesW backend.
//
// Watches each unique directory with a single overlapped
// `ReadDirectoryChangesW` request. `WaitForMultipleObjectsEx` blocks on
// the per-directory completion events with a timeout; on wake we walk
// the FILE_NOTIFY_INFORMATION buffer, look the basename up in the
// directory's binding list, and mark the relevant jobs.
//
// Modeled after `std.Build.Watch`'s Windows branch; simplified because
// we only need single-directory watches (no recursion) and we own the
// process lifetime so we don't need an APC-driven loop.
// =============================================================================

// std.os.windows in 0.16 only exposes a small slice of the Win32 surface
// (mostly NT-API plumbing); the file-watch flavor of ReadDirectoryChangesW
// lives entirely behind these manual extern declarations. Field/parameter
// types match the official Win32 SDK headers (winbase.h / minwinbase.h /
// fileapi.h / synchapi.h).
const win_api = struct {
    pub const HANDLE = *anyopaque;
    pub const DWORD = u32;
    pub const BOOL = c_int;
    pub const LPVOID = ?*anyopaque;
    pub const LPCVOID = ?*const anyopaque;
    pub const LPDWORD = ?*DWORD;

    pub const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));
    pub const INFINITE: DWORD = 0xFFFFFFFF;
    pub const WAIT_OBJECT_0: DWORD = 0x00000000;
    pub const WAIT_TIMEOUT: DWORD = 0x00000102;
    pub const WAIT_FAILED: DWORD = 0xFFFFFFFF;

    pub const GENERIC_READ: DWORD = 0x80000000;
    pub const FILE_SHARE_READ: DWORD = 0x00000001;
    pub const FILE_SHARE_WRITE: DWORD = 0x00000002;
    pub const FILE_SHARE_DELETE: DWORD = 0x00000004;
    pub const OPEN_EXISTING: DWORD = 3;
    pub const FILE_FLAG_OVERLAPPED: DWORD = 0x40000000;
    pub const FILE_FLAG_BACKUP_SEMANTICS: DWORD = 0x02000000;

    pub const FILE_NOTIFY_CHANGE_FILE_NAME: DWORD = 0x00000001;
    pub const FILE_NOTIFY_CHANGE_DIR_NAME: DWORD = 0x00000002;
    pub const FILE_NOTIFY_CHANGE_LAST_WRITE: DWORD = 0x00000010;
    pub const FILE_NOTIFY_CHANGE_SIZE: DWORD = 0x00000008;
    pub const FILE_NOTIFY_CHANGE_CREATION: DWORD = 0x00000040;

    pub const OVERLAPPED = extern struct {
        Internal: usize = 0,
        InternalHigh: usize = 0,
        DUMMYUNIONNAME: extern union {
            DUMMYSTRUCTNAME: extern struct { Offset: DWORD, OffsetHigh: DWORD },
            Pointer: ?*anyopaque,
        } = .{ .DUMMYSTRUCTNAME = .{ .Offset = 0, .OffsetHigh = 0 } },
        hEvent: ?HANDLE = null,
    };

    // FILE_NOTIFY_INFORMATION has a trailing variable-length WCHAR array
    // (`WCHAR FileName[1]`). We treat the struct as fixed-size and reach
    // out-of-bounds via `@ptrCast` of the trailing field at runtime;
    // that's the same shape the Win32 SDK declares.
    pub const FILE_NOTIFY_INFORMATION = extern struct {
        NextEntryOffset: DWORD,
        Action: DWORD,
        FileNameLength: DWORD,
        FileName: [1]u16 align(1),
    };

    pub const SECURITY_ATTRIBUTES = extern struct {
        nLength: DWORD,
        lpSecurityDescriptor: ?*anyopaque,
        bInheritHandle: BOOL,
    };

    pub extern "kernel32" fn CreateFileW(
        lpFileName: [*:0]const u16,
        dwDesiredAccess: DWORD,
        dwShareMode: DWORD,
        lpSecurityAttributes: ?*SECURITY_ATTRIBUTES,
        dwCreationDisposition: DWORD,
        dwFlagsAndAttributes: DWORD,
        hTemplateFile: ?HANDLE,
    ) callconv(.winapi) HANDLE;

    pub extern "kernel32" fn CreateEventW(
        lpEventAttributes: ?*SECURITY_ATTRIBUTES,
        bManualReset: BOOL,
        bInitialState: BOOL,
        lpName: ?[*:0]const u16,
    ) callconv(.winapi) ?HANDLE;

    pub extern "kernel32" fn ResetEvent(hEvent: HANDLE) callconv(.winapi) BOOL;
    pub extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;

    pub extern "kernel32" fn ReadDirectoryChangesW(
        hDirectory: HANDLE,
        lpBuffer: LPVOID,
        nBufferLength: DWORD,
        bWatchSubtree: BOOL,
        dwNotifyFilter: DWORD,
        lpBytesReturned: LPDWORD,
        lpOverlapped: ?*OVERLAPPED,
        lpCompletionRoutine: ?*anyopaque,
    ) callconv(.winapi) BOOL;

    pub extern "kernel32" fn CancelIoEx(
        hFile: HANDLE,
        lpOverlapped: ?*OVERLAPPED,
    ) callconv(.winapi) BOOL;

    pub extern "kernel32" fn GetOverlappedResult(
        hFile: HANDLE,
        lpOverlapped: *OVERLAPPED,
        lpNumberOfBytesTransferred: *DWORD,
        bWait: BOOL,
    ) callconv(.winapi) BOOL;

    pub extern "kernel32" fn WaitForSingleObject(
        hHandle: HANDLE,
        dwMilliseconds: DWORD,
    ) callconv(.winapi) DWORD;

    pub extern "kernel32" fn WaitForMultipleObjectsEx(
        nCount: DWORD,
        lpHandles: [*]const HANDLE,
        bWaitAll: BOOL,
        dwMilliseconds: DWORD,
        bAlertable: BOOL,
    ) callconv(.winapi) DWORD;
};

const WindowsRdcw = struct {
    /// canonical directory path -> per-directory state. The string key
    /// shares the allocation with `DirState.dir_path` so teardown frees
    /// it once via the value iterator below.
    dirs: std.StringHashMapUnmanaged(*DirState) = .empty,

    const DirState = struct {
        dir_path: []u8,
        handle: win_api.HANDLE,
        completion: win_api.HANDLE,
        overlapped: win_api.OVERLAPPED,
        buffer: [4096]u8 align(4),
        bindings: std.ArrayListUnmanaged(FileBinding) = .empty,
        pending: bool = false,
    };

    pub fn init(_: std.mem.Allocator) !WindowsRdcw {
        return .{};
    }

    pub fn deinit(self: *WindowsRdcw, allocator: std.mem.Allocator) void {
        self.clearWatches(allocator);
        self.dirs.deinit(allocator);
    }

    pub fn clearWatches(self: *WindowsRdcw, allocator: std.mem.Allocator) void {
        var it = self.dirs.valueIterator();
        while (it.next()) |d_ptr| {
            const d = d_ptr.*;
            if (d.pending) {
                _ = win_api.CancelIoEx(d.handle, &d.overlapped);
                _ = win_api.WaitForSingleObject(d.completion, win_api.INFINITE);
            }
            _ = win_api.CloseHandle(d.handle);
            _ = win_api.CloseHandle(d.completion);
            freeBindings(allocator, &d.bindings);
            allocator.free(d.dir_path);
            allocator.destroy(d);
        }
        self.dirs.clearRetainingCapacity();
    }

    pub fn addWatchedFile(
        self: *WindowsRdcw,
        allocator: std.mem.Allocator,
        path: []const u8,
        job_index: u32,
    ) !void {
        const split = splitDirAndBasename(path);

        const dir_state: *DirState = if (self.dirs.get(split.dir)) |existing|
            existing
        else blk: {
            const dir_dup = try allocator.dupe(u8, split.dir);
            errdefer allocator.free(dir_dup);

            const new_state = try allocator.create(DirState);
            errdefer allocator.destroy(new_state);

            const handle = try openDirectoryHandle(split.dir);
            errdefer _ = win_api.CloseHandle(handle);
            const completion = win_api.CreateEventW(null, 1, 0, null) orelse
                return error.Unexpected;
            errdefer _ = win_api.CloseHandle(completion);

            new_state.* = .{
                .dir_path = dir_dup,
                .handle = handle,
                .completion = completion,
                .overlapped = .{},
                // SAFETY: only ever written by ReadDirectoryChangesW
                // and read up to the kernel-reported `bytes_returned`.
                .buffer = undefined,
            };
            new_state.overlapped.hEvent = completion;

            try self.dirs.put(allocator, dir_dup, new_state);
            try issueRead(new_state);
            break :blk new_state;
        };

        if (bindingsHas(dir_state.bindings.items, split.base, job_index)) return;
        const base_dup = try allocator.dupe(u8, split.base);
        errdefer allocator.free(base_dup);
        try dir_state.bindings.append(allocator, .{ .name = base_dup, .job_index = job_index });
    }

    fn openDirectoryHandle(path: []const u8) !win_api.HANDLE {
        var path_w_buf: [std.fs.max_path_bytes]u16 = undefined;
        const path_w_len = try std.unicode.utf8ToUtf16Le(path_w_buf[0 .. path_w_buf.len - 1], path);
        path_w_buf[path_w_len] = 0;
        const path_w: [*:0]const u16 = @ptrCast(&path_w_buf);

        const handle = win_api.CreateFileW(
            path_w,
            win_api.GENERIC_READ,
            win_api.FILE_SHARE_READ | win_api.FILE_SHARE_WRITE | win_api.FILE_SHARE_DELETE,
            null,
            win_api.OPEN_EXISTING,
            win_api.FILE_FLAG_BACKUP_SEMANTICS | win_api.FILE_FLAG_OVERLAPPED,
            null,
        );
        if (handle == win_api.INVALID_HANDLE_VALUE) return error.Unexpected;
        return handle;
    }

    fn issueRead(d: *DirState) !void {
        const filter: win_api.DWORD = win_api.FILE_NOTIFY_CHANGE_FILE_NAME |
            win_api.FILE_NOTIFY_CHANGE_DIR_NAME |
            win_api.FILE_NOTIFY_CHANGE_LAST_WRITE |
            win_api.FILE_NOTIFY_CHANGE_SIZE |
            win_api.FILE_NOTIFY_CHANGE_CREATION;
        _ = win_api.ResetEvent(d.completion);
        var bytes_returned: win_api.DWORD = 0;
        const ok = win_api.ReadDirectoryChangesW(
            d.handle,
            &d.buffer,
            d.buffer.len,
            0, // don't recurse
            filter,
            &bytes_returned,
            &d.overlapped,
            null,
        );
        if (ok == 0) return error.Unexpected;
        d.pending = true;
    }

    pub fn waitForChange(
        self: *WindowsRdcw,
        timeout_ms: u32,
        out_dirty: []bool,
    ) !bool {
        if (self.dirs.count() == 0) {
            // Nothing registered yet -- watch loop is between collect
            // passes. Block for the timeout so we don't spin.
            sleepIgnoringCancel(timeout_ms);
            return false;
        }

        var handles_buf: [64]win_api.HANDLE = undefined;
        var dirs_buf: [64]*DirState = undefined;
        var cap: usize = 0;
        var it = self.dirs.valueIterator();
        while (it.next()) |d_ptr| {
            if (cap >= handles_buf.len) break;
            dirs_buf[cap] = d_ptr.*;
            handles_buf[cap] = d_ptr.*.completion;
            cap += 1;
        }

        const wait_rc = win_api.WaitForMultipleObjectsEx(
            @intCast(cap),
            &handles_buf,
            0,
            timeout_ms,
            0,
        );
        if (wait_rc == win_api.WAIT_TIMEOUT) return false;
        if (wait_rc == win_api.WAIT_FAILED) return error.Unexpected;
        const idx: usize = @intCast(wait_rc - win_api.WAIT_OBJECT_0);
        if (idx >= cap) return false;

        const d = dirs_buf[idx];
        var bytes_returned: win_api.DWORD = 0;
        if (win_api.GetOverlappedResult(d.handle, &d.overlapped, &bytes_returned, 0) == 0) {
            d.pending = false;
            try issueRead(d);
            return false;
        }
        d.pending = false;

        var any = false;
        var off: usize = 0;
        while (off < bytes_returned) {
            const info: *const win_api.FILE_NOTIFY_INFORMATION =
                @ptrCast(@alignCast(&d.buffer[off]));
            const name_w_len = info.FileNameLength / @sizeOf(u16);
            const name_w_ptr: [*]const u16 = @ptrCast(&info.FileName);
            const name_w = name_w_ptr[0..name_w_len];

            var name_buf: [std.fs.max_path_bytes]u8 = undefined;
            const name_len = std.unicode.utf16LeToUtf8(name_buf[0..], name_w) catch 0;
            const name = name_buf[0..name_len];

            for (d.bindings.items) |fb| {
                if (!std.mem.eql(u8, fb.name, name)) continue;
                if (fb.job_index >= out_dirty.len) continue;
                out_dirty[fb.job_index] = true;
                any = true;
            }

            if (info.NextEntryOffset == 0) break;
            off += info.NextEntryOffset;
        }

        try issueRead(d);
        return any;
    }
};

// =============================================================================
// Polling fallback. Functionally identical to the previous mtime poll
// loop but exposed through the same WatchBackend API so callers don't
// have to special-case unsupported targets.
// =============================================================================

const Polling = struct {
    paths: std.ArrayListUnmanaged(Entry) = .empty,

    const Entry = struct {
        path: []u8,
        mtime: i96,
        job_index: u32,
    };

    pub fn init(_: std.mem.Allocator) !Polling {
        return .{};
    }

    pub fn deinit(self: *Polling, allocator: std.mem.Allocator) void {
        self.clearWatches(allocator);
    }

    pub fn clearWatches(self: *Polling, allocator: std.mem.Allocator) void {
        for (self.paths.items) |e| allocator.free(e.path);
        self.paths.clearAndFree(allocator);
    }

    pub fn addWatchedFile(
        self: *Polling,
        allocator: std.mem.Allocator,
        path: []const u8,
        job_index: u32,
    ) !void {
        for (self.paths.items) |e| {
            if (e.job_index == job_index and std.mem.eql(u8, e.path, path)) return;
        }
        const path_dup = try allocator.dupe(u8, path);
        errdefer allocator.free(path_dup);
        const st = std.Io.Dir.cwd().statFile(zsass_io.io, path, .{}) catch {
            try self.paths.append(allocator, .{ .path = path_dup, .mtime = 0, .job_index = job_index });
            return;
        };
        try self.paths.append(allocator, .{
            .path = path_dup,
            .mtime = st.mtime.nanoseconds,
            .job_index = job_index,
        });
    }

    pub fn waitForChange(
        self: *Polling,
        timeout_ms: u32,
        out_dirty: []bool,
    ) !bool {
        sleepIgnoringCancel(timeout_ms);
        var any = false;
        for (self.paths.items) |*e| {
            const st = std.Io.Dir.cwd().statFile(zsass_io.io, e.path, .{}) catch {
                if (e.mtime != 0) {
                    e.mtime = 0;
                    if (e.job_index < out_dirty.len) {
                        out_dirty[e.job_index] = true;
                        any = true;
                    }
                }
                continue;
            };
            if (st.mtime.nanoseconds != e.mtime) {
                e.mtime = st.mtime.nanoseconds;
                if (e.job_index < out_dirty.len) {
                    out_dirty[e.job_index] = true;
                    any = true;
                }
            }
        }
        return any;
    }
};

test "splitDirAndBasename peels off basename and keeps relative dir" {
    {
        const r = splitDirAndBasename("foo/bar/baz.scss");
        try std.testing.expectEqualStrings("foo/bar", r.dir);
        try std.testing.expectEqualStrings("baz.scss", r.base);
    }
    {
        const r = splitDirAndBasename("only.scss");
        try std.testing.expectEqualStrings(".", r.dir);
        try std.testing.expectEqualStrings("only.scss", r.base);
    }
    {
        const r = splitDirAndBasename("/abs/path/x.scss");
        try std.testing.expectEqualStrings("/abs/path", r.dir);
        try std.testing.expectEqualStrings("x.scss", r.base);
    }
}

// dart-sass parity for the watcher: a write that lands on a file
// registered against `job_index = N` must surface as `out_dirty[N] = true`
// while every unrelated index stays `false`. This is the cross-cutting
// invariant the per-job recompile in `runWatchLoop` depends on; if a
// backend regresses to "any change dirties every job" or "no event ever
// fires", the assertions below catch it. Linux-only because it's the
// only backend that can be exercised end-to-end in this CI.
test "WatchBackend reports only the job that owns the changed file (linux)" {
    if (builtin.os.tag != .linux) return;

    var td = std.testing.tmpDir(.{});
    defer td.cleanup();

    const allocator = std.testing.allocator;
    const sub = td.sub_path[0..];

    var paths: [3][]u8 = undefined;
    inline for (.{ "a", "b", "c" }, 0..) |name, i| {
        paths[i] = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/{s}.scss", .{ sub, name });
        const f = try std.fs.cwd().createFile(paths[i], .{});
        try f.writeAll(".x{}\n");
        f.close();
    }
    defer for (paths) |p| allocator.free(p);

    var watcher = try WatchBackend.init(allocator);
    defer watcher.deinit(allocator);
    for (paths, 0..) |p, i| try watcher.addWatchedFile(allocator, p, @intCast(i));

    // No write yet: a short timeout should expire without dirtying anything.
    var dirty: [3]bool = .{ false, false, false };
    const before = try watcher.waitForChange(50, &dirty);
    try std.testing.expect(!before);
    try std.testing.expectEqual(false, dirty[0]);
    try std.testing.expectEqual(false, dirty[1]);
    try std.testing.expectEqual(false, dirty[2]);

    // Touch index 1 only.
    {
        const f = try std.fs.cwd().createFile(paths[1], .{ .truncate = true });
        try f.writeAll(".x-changed{}\n");
        f.close();
    }

    // inotify is event-driven so the wait should return promptly with
    // exactly index 1 flipped. Allow 1s headroom for slow CI runners.
    const after = try watcher.waitForChange(1000, &dirty);
    try std.testing.expect(after);
    try std.testing.expectEqual(false, dirty[0]);
    try std.testing.expectEqual(true, dirty[1]);
    try std.testing.expectEqual(false, dirty[2]);
}
