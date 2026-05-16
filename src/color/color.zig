const std = @import("std");
const math = std.math;

// Use the libm `pow` directly. `std.math.pow(f64, ...)` differs from
// libm by 1 ULP on extreme-range RGB transfer inputs (e.g. A98 1e15
// channels), which sass-spec / official `sass` CLI parity depend on.
// See the color audit ledger ("Route `powRational()` through
// libc `pow()` ...").
extern fn pow(f64, f64) f64;

// ============================================================================
// Types
// ============================================================================

pub const ColorSpace = enum {
    srgb,
    srgb_linear,
    hsl,
    hwb,
    lab,
    lch,
    oklab,
    oklch,
    display_p3,
    display_p3_linear,
    a98_rgb,
    prophoto_rgb,
    rec2020,
    xyz_d50,
    xyz_d65,

    /// Returns true if this space uses polar (hue) coordinates.
    pub fn isPolar(self: ColorSpace) bool {
        return switch (self) {
            .hsl, .hwb, .lch, .oklch => true,
            else => false,
        };
    }

    /// Returns the gamut limits for each channel as [min, max] pairs.
    /// Returns null for unbounded spaces (Lab, LCH, OKLab, OKLCH, XYZ).
    pub fn gamutBounds(self: ColorSpace) ?[3][2]f64 {
        return switch (self) {
            .srgb, .srgb_linear, .display_p3, .display_p3_linear, .a98_rgb, .prophoto_rgb, .rec2020 => .{
                .{ 0.0, 1.0 },
                .{ 0.0, 1.0 },
                .{ 0.0, 1.0 },
            },
            .hsl => .{
                .{ 0.0, 360.0 },
                .{ 0.0, 100.0 },
                .{ 0.0, 100.0 },
            },
            .hwb => .{
                .{ 0.0, 360.0 },
                .{ 0.0, 100.0 },
                .{ 0.0, 100.0 },
            },
            else => null,
        };
    }
};

pub const Color = struct {
    channels: [4]f64, // c0, c1, c2, alpha
    space: ColorSpace,

    pub fn init(c0: f64, c1: f64, c2: f64, a: f64, space: ColorSpace) Color {
        return .{
            .channels = .{ c0, c1, c2, a },
            .space = space,
        };
    }

    pub fn eql(self: Color, other: Color, tol: f64) bool {
        if (self.space != other.space) return false;
        for (0..4) |i| {
            if (@abs(self.channels[i] - other.channels[i]) > tol) return false;
        }
        return true;
    }
};

pub const ColorRepr = enum(u4) {
    legacy = 0,
    literal_short_hex = 1,
    literal_long_hex = 2,
    rgb_fn = 3,
    hsl_fn = 4,
    literal_named = 5,
    literal_transparent = 6,
};

pub const ColorMissingMask = u4;

pub const ColorValue = struct {
    r: f64 = 0,
    g: f64 = 0,
    b: f64 = 0,
    a: f64 = 1,
    h: f64 = 0,
    s: f64 = 0,
    l: f64 = 0,
    repr: ColorRepr = .legacy,
    space: ?ColorSpace = null,
    c0: f64 = 0,
    c1: f64 = 0,
    c2: f64 = 0,
    missing: ColorMissingMask = 0,
    uppercase_hex: bool = false,
    modern_hsl_syntax: bool = false,
    modern_hwb_syntax: bool = false,
};

// ============================================================================
// Conversion Matrices (from CSS Color Level 4 spec)
// ============================================================================

/// 3x3 matrix type stored row-major.
const Matrix3 = [3][3]f64;

/// Multiply 3x3 matrix by 3-element column vector.
fn mulMV(m: Matrix3, v: [3]f64) [3]f64 {
    const x0: f80 = @as(f80, @floatCast(m[0][0])) * @as(f80, @floatCast(v[0])) +
        @as(f80, @floatCast(m[0][1])) * @as(f80, @floatCast(v[1])) +
        @as(f80, @floatCast(m[0][2])) * @as(f80, @floatCast(v[2]));
    const x1: f80 = @as(f80, @floatCast(m[1][0])) * @as(f80, @floatCast(v[0])) +
        @as(f80, @floatCast(m[1][1])) * @as(f80, @floatCast(v[1])) +
        @as(f80, @floatCast(m[1][2])) * @as(f80, @floatCast(v[2]));
    const x2: f80 = @as(f80, @floatCast(m[2][0])) * @as(f80, @floatCast(v[0])) +
        @as(f80, @floatCast(m[2][1])) * @as(f80, @floatCast(v[1])) +
        @as(f80, @floatCast(m[2][2])) * @as(f80, @floatCast(v[2]));
    return .{
        @as(f64, @floatCast(x0)),
        @as(f64, @floatCast(x1)),
        @as(f64, @floatCast(x2)),
    };
}

fn mulMV64(m: Matrix3, v: [3]f64) [3]f64 {
    // OKLab sample algorithms are specified in terms of ordinary binary64
    // matrix products; extended accumulation changes observable roundoff.
    return .{
        m[0][0] * v[0] + m[0][1] * v[1] + m[0][2] * v[2],
        m[1][0] * v[0] + m[1][1] * v[1] + m[1][2] * v[2],
        m[2][0] * v[0] + m[2][1] * v[1] + m[2][2] * v[2],
    };
}

/// Apply a per-channel transfer function to a 3-element vector.
fn mapChannels(comptime f: fn (f64) f64, v: [3]f64) [3]f64 {
    return .{ f(v[0]), f(v[1]), f(v[2]) };
}

fn powRational(base: f64, numerator: u16, denominator: u16) f64 {
    if (base == 0.0 or base == 1.0 or numerator == denominator) return base;
    return pow(base, @as(f64, @floatFromInt(numerator)) / @as(f64, @floatFromInt(denominator)));
}

fn signedPowCbrt(value: f64) f64 {
    if (value == 0.0) return value;
    const sign: f64 = if (value < 0.0) -1.0 else 1.0;
    return sign * pow(@abs(value), 1.0 / 3.0);
}

// --- sRGB Linear <-> XYZ-D65 ---

const srgb_to_xyz_d65: Matrix3 = .{
    .{ 506752.0 / 1228815.0, 87881.0 / 245763.0, 12673.0 / 70218.0 },
    .{ 87098.0 / 409605.0, 175762.0 / 245763.0, 12673.0 / 175545.0 },
    .{ 7918.0 / 409605.0, 87881.0 / 737289.0, 1001167.0 / 1053270.0 },
};

const xyz_d65_to_srgb: Matrix3 = .{
    .{ 12831.0 / 3959.0, -329.0 / 214.0, -1974.0 / 3959.0 },
    .{ -851781.0 / 878810.0, 1648619.0 / 878810.0, 36519.0 / 878810.0 },
    .{ 705.0 / 12673.0, -2585.0 / 12673.0, 705.0 / 667.0 },
};

const srgb_to_xyz_d50: Matrix3 = .{
    .{ 0.43606574687426936, 0.3851515095901596, 0.14307841996513867 },
    .{ 0.22249317711056518, 0.7168870130944824, 0.06061980979495235 },
    .{ 0.01392392146316939, 0.09708132423141015, 0.71409935681588066 },
};

const xyz_d50_to_srgb_linear_direct: Matrix3 = .{
    .{ 3.1341358529001178, -1.617385998018042, -0.4906622179110975 },
    .{ -0.9787954765557777, 1.9162543773959881, 0.03344287339036693 },
    .{ 0.07195539255794733, -0.22897675981518206, 1.4053860351131182 },
};

// --- Display-P3 Linear <-> XYZ-D65 ---

const display_p3_to_xyz_d65: Matrix3 = .{
    .{ 608311.0 / 1250200.0, 189793.0 / 714400.0, 198249.0 / 1000160.0 },
    .{ 35783.0 / 156275.0, 247089.0 / 357200.0, 198249.0 / 2500400.0 },
    .{ 0.0, 32229.0 / 714400.0, 5220557.0 / 5000800.0 },
};

const xyz_d65_to_display_p3: Matrix3 = .{
    .{ 446124.0 / 178915.0, -333277.0 / 357830.0, -72051.0 / 178915.0 },
    .{ -14852.0 / 17905.0, 63121.0 / 35810.0, 423.0 / 17905.0 },
    .{ 0.03584583024378433, -50337.0 / 660830.0, 316169.0 / 330415.0 },
};

const xyz_d65_to_display_p3_direct: Matrix3 = .{
    .{ 446124.0 / 178915.0, -333277.0 / 357830.0, -72051.0 / 178915.0 },
    .{ -0.8294889695615749, 63121.0 / 35810.0, 423.0 / 17905.0 },
    .{ 0.03584583024378433, -50337.0 / 660830.0, 316169.0 / 330415.0 },
};

const xyz_d65_to_display_p3_from_lch: Matrix3 = .{
    .{ 2.4934969119414254, -333277.0 / 357830.0, -72051.0 / 178915.0 },
    .{ -14852.0 / 17905.0, 63121.0 / 35810.0, 423.0 / 17905.0 },
    .{ 0.035845830243784335, -50337.0 / 660830.0, 316169.0 / 330415.0 },
};

const display_p3_to_xyz_d50: Matrix3 = .{
    .{ 0.515146442968116, 0.2920099820638577, 0.15713925139759397 },
    .{ 0.2412003221252552, 0.6922225411313819, 0.06657713674336294 },
    .{ -0.00105013914714014, 0.0418782701890746, 0.7842764714685258 },
};

const display_p3_to_srgb_linear: Matrix3 = .{
    .{ 1.2249401762805598, -0.22494017628055997, 0.0 },
    .{ -0.042056954709688164, 1.0420569547096881, 0.0 },
    .{ -0.01963755459033443, -0.07863604555063188, 1.0982736001409662 },
};

const srgb_to_display_p3_linear: Matrix3 = .{
    .{ 0.8224619687143623, 0.17753803128563775, 0.0 },
    .{ 0.03319419885096161, 0.9668058011490384, 0.0 },
    .{ 0.01708263072112003, 0.07239744066396346, 0.9105199286149165 },
};

const srgb_to_prophoto_linear: Matrix3 = .{
    .{ 0.52927697762261161, 0.33015450197849272, 0.14056852039889559 },
    .{ 0.098365859540449185, 0.87347071290696199, 0.028163427552588993 },
    .{ 0.01687534092138684, 0.11765941425612084, 0.86546524482249221 },
};

const srgb_to_rec2020_linear: Matrix3 = .{
    .{ 0.62740389593469903, 0.32928303837788359, 0.043313065687417246 },
    .{ 0.06909728935823206, 0.91954039507545848, 0.011362315566309159 },
    .{ 0.01639143887515027, 0.088013307877225763, 0.89559525324762401 },
};

// --- A98-RGB Linear <-> XYZ-D65 ---

const a98_rgb_to_xyz_d65: Matrix3 = .{
    .{ 0.5766690429101308, 0.18555823790654627, 0.18822864623499472 },
    .{ 0.29734497525053616, 0.627363566255466, 0.07529145849399789 },
    .{ 0.02703136138641237, 0.07068885253582714, 0.9913375368376389 },
};

const xyz_d65_to_a98_rgb: Matrix3 = .{
    .{ 1829569.0 / 896150.0, -506331.0 / 896150.0, -308931.0 / 896150.0 },
    .{ -851781.0 / 878810.0, 1648619.0 / 878810.0, 36519.0 / 878810.0 },
    .{ 0.013444280632031035, -147721.0 / 1248040.0, 1.0151749943912056 },
};

const a98_rgb_to_xyz_d50: Matrix3 = .{
    .{ 0.6097750418861814, 0.20530000261929397, 0.14922063192409225 },
    .{ 0.31112461220464156, 0.6256532308346855, 0.06322215696067286 },
    .{ 0.01947059555648168, 0.06087908649415867, 0.7447549204598199 },
};

const a98_rgb_to_display_p3_linear: Matrix3 = .{
    .{ 1.1500944181410184, -0.15009441814101834, 0.0 },
    .{ 0.04641729862941844, 0.9535827013705815, 0.0 },
    .{ 0.02388759479083904, 0.02650477632633013, 0.9496076288828308 },
};

const a98_rgb_to_prophoto_linear: Matrix3 = .{
    .{ 0.7401175018047792, 0.11327951328898096, 0.14660298490623963 },
    .{ 0.13755046469802620, 0.83307708026948402, 0.029372455032489773 },
    .{ 0.023597729908717658, 0.073783477039066542, 0.90261879305221582 },
};

const display_p3_to_a98_rgb_linear: Matrix3 = .{
    .{ 0.8640051374740485, 0.13599486252595155, 0.0 },
    .{ -0.04205695470968818, 1.0420569547096878, 0.0 },
    .{ -0.020560380782329843, -0.032506138045507969, 1.0530665188278376 },
};

// --- ProPhoto-RGB Linear <-> XYZ-D50 ---

const prophoto_to_xyz_d50: Matrix3 = .{
    .{ 0.79776664490064230, 0.13518129740053308, 0.03134773412839220 },
    .{ 0.28807482881940130, 0.71183523424187300, 0.00008993693872564 },
    .{ 0.00000000000000000, 0.00000000000000000, 0.82510460251046020 },
};

const xyz_d50_to_prophoto: Matrix3 = .{
    .{ 1.34578688164715830, -0.25557208737979464, -0.05110186497554526 },
    .{ -0.54463070512490190, 1.50824774284514680, 0.02052744743642139 },
    .{ 0.00000000000000000, 0.00000000000000000, 1.21196754563894520 },
};

const prophoto_to_xyz_d65: Matrix3 = .{
    .{ 0.7555907422969209, 0.11271984265940525, 0.0821453420953454 },
    .{ 0.2683218435785719, 0.7151152566617911, 0.016562899759636848 },
    .{ 0.0039159727624258, -0.012933442836841809, 1.0980752208342946 },
};

const prophoto_to_srgb_linear: Matrix3 = .{
    .{ 2.0343808495169959, -0.7276357899341341, -0.3067450595828618 },
    .{ -0.22882573163305038, 1.231742541190105, -0.00291680955705449 },
    .{ -0.008558828783917419, -0.15326670213803722, 1.1618255309219548 },
};

const prophoto_to_display_p3_linear: Matrix3 = .{
    .{ 1.6325756087069178, -0.37977161848259844, -0.2528039902243195 },
    .{ -0.15370040233755072, 1.1667025472425012, -0.013002144904950818 },
    .{ 0.01039319529676572, -0.0628073126495944, 1.0524141173528289 },
};

const display_p3_to_prophoto_linear: Matrix3 = .{
    .{ 0.63168691934035881, 0.21393038569465711, 0.15438269496498389 },
    .{ 0.08320371426648458, 0.88586513676302425, 0.030931148970491224 },
    .{ -0.0012727345647388104, 0.050755104336657343, 0.95051763022808133 },
};

const display_p3_to_rec2020_linear: Matrix3 = .{
    .{ 0.7538330343617219, 0.19859736905261627, 0.047569596585661844 },
    .{ 0.045743848965358325, 0.94177721981169338, 0.012478931222948103 },
    .{ -0.0012103403545183200, 0.017601717301089892, 0.98360862305342833 },
};

// --- Rec2020 Linear <-> XYZ-D65 ---

const rec2020_to_xyz_d65: Matrix3 = .{
    .{ 63426534.0 / 99577255.0, 20160776.0 / 139408157.0, 47086771.0 / 278816314.0 },
    .{ 26158966.0 / 99577255.0, 472592308.0 / 697040785.0, 8267143.0 / 139408157.0 },
    .{ 0.0, 19567812.0 / 697040785.0, 295819943.0 / 278816314.0 },
};

const xyz_d65_to_rec2020: Matrix3 = .{
    .{ 30757411.0 / 17917100.0, -6372589.0 / 17917100.0, -4539589.0 / 17917100.0 },
    .{ -19765991.0 / 29648200.0, 1.6164812366349388, 467509.0 / 29648200.0 },
    .{ 792561.0 / 44930125.0, -1921689.0 / 44930125.0, 42328811.0 / 44930125.0 },
};

const rec2020_to_xyz_d50: Matrix3 = .{
    .{ 0.673515463188276, 0.16569726370390453, 0.12508294953738705 },
    .{ 0.27905900514112056, 0.6753180057491098, 0.045622989109769625 },
    .{ -0.0019324271340043801, 0.02997782679282923, 0.7970592028516354 },
};

const rec2020_to_srgb_linear: Matrix3 = .{
    .{ 1.6604910021084344, -0.5876411387885496, -0.07284986331988488 },
    .{ -0.12455047452159074, 1.1328998971259602, -0.00834942260436947 },
    .{ -0.0181507633549053, -0.10057889800800738, 1.1187296613629128 },
};

const rec2020_to_display_p3_linear: Matrix3 = .{
    .{ 1.343578252584332, -0.2821796705261357, -0.06139858205819628 },
    .{ -0.06529745278911952, 1.0757879158485745, -0.010490463059454951 },
    .{ 0.00282178726170095, -0.019598494524494062, 1.016776707262793 },
};

const rec2020_to_prophoto_linear: Matrix3 = .{
    .{ 0.8351873331297234, 0.048868848586056945, 0.11594381828421949 },
    .{ 0.05403324519953362, 0.92891840856920449, 0.017048346231262002 },
    .{ -0.0023420389707253901, 0.03633215316169465, 0.96600988580903069 },
};

// --- Bradford chromatic adaptation D50 <-> D65 ---

const d50_to_d65: Matrix3 = .{
    .{ 0.95547342148807520, -0.02309845494876452, 0.06325924320057065 },
    .{ -0.02836970933386358, 1.00999539808130410, 0.021041441191917303 },
    .{ 0.01231401486448199, -0.02050764929889898, 1.33036592624212400 },
};

const d65_to_d50: Matrix3 = .{
    .{ 1.04792979254499660, 0.02294687060160952, -0.05019226628920519 },
    .{ 0.02962780877005567, 0.99043442675388000, -0.01707379906341879 },
    .{ -0.00924304064620452, 0.01505519149029816, 0.75187428142813700 },
};

// --- OKLab <-> XYZ-D65 ---
// OKLab uses two matrices: XYZ -> LMS, then LMS^(1/3) -> Lab

const xyz_d65_to_lms: Matrix3 = .{
    .{ 0.81902243799670300, 0.36190626005289034, -0.12887378152098788 },
    .{ 0.03298365393238846, 0.92928686158634330, 0.03614466635064235 },
    .{ 0.04817718935962420, 0.26423953175273080, 0.63354782846943080 },
};

const lms_to_xyz_d65: Matrix3 = .{
    .{ 1.22687987584592430, -0.55781499446021710, 0.28139104566596460 },
    .{ -0.04057574521480084, 1.11228680328031730, -0.07171105806551635 },
    .{ -0.07637293667466007, -0.42149333240224324, 1.58692401983678180 },
};

const lms_cbrt_to_oklab: Matrix3 = .{
    .{ 0.21045426830931400, 0.79361777470230540, -0.00407204301161930 },
    .{ 1.97799853243116840, -2.42859224204858000, 0.45059370961741100 },
    .{ 0.02590404246554780, 0.78277171245752960, -0.80867575492307740 },
};

const oklab_to_lms_cbrt: Matrix3 = .{
    .{ 1.00000000000000020, 0.39633777737617490, 0.21580375730991360 },
    .{ 0.99999999999999980, -0.10556134581565854, -0.06385417282581334 },
    .{ 0.99999999999999990, -0.08948417752981180, -1.29148554801940940 },
};

const lms_to_display_p3_linear: Matrix3 = .{
    .{ 3.1277689713618737, -2.2571357625916382, 0.12936679122976488 },
    .{ -1.0910090184377979, 2.4133317103069225, -0.32232269186912466 },
    .{ -0.026010801938570447, -0.50804133170416699, 1.5340521336427375 },
};

const lms_to_xyz_d50_direct: Matrix3 = .{
    .{ 1.2885862181727061, -0.53787174449737452, 0.21358120275423639 },
    .{ -0.0025338764318737208, 1.0923167988719165, -0.089782922440042712 },
    .{ -0.06937382305734124, -0.29500839894431258, 1.1894868245121142 },
};

const lms_to_prophoto_linear_direct: Matrix3 = .{
    .{ 1.7383551481157209, -0.98795094275144579, 0.24959579463572501 },
    .{ -0.70704940153292661, 1.9343700444401384, -0.22732064290721149 },
    .{ -0.084078822062396336, -0.35754060521141334, 1.4416194272738097 },
};

const lms_to_a98_linear_direct: Matrix3 = .{
    .{ 2.5540368386115566, -1.6219761806828701, 0.067939342071313386 },
    .{ -1.2684379732850319, 2.6097573492876891, -0.3413193760026571 },
    .{ -0.05623473593749381, -0.56704183956690624, 1.6232765755044003 },
};

const linear_srgb_to_lms: Matrix3 = .{
    .{ 0.41222146947076300, 0.53633253726173480, 0.05144599326750220 },
    .{ 0.21190349581782520, 0.68069955064523420, 0.10739695353694050 },
    .{ 0.08830245919005641, 0.28171883913612150, 0.62997870167382210 },
};

const lms_to_linear_srgb: Matrix3 = .{
    .{ 4.07674163607595800, -3.30771153925806200, 0.23096990318210417 },
    .{ -1.26843797328503200, 2.60975734928768900, -0.34131937600265710 },
    .{ -0.00419607613867551, -0.70341861793593630, 1.70761469407461200 },
};

// ============================================================================
// Gamma / Transfer Functions
// ============================================================================

/// sRGB companding: linear -> gamma-corrected
fn srgbGamma(linear: f64) f64 {
    const abs_linear = @abs(linear);
    const sign: f64 = if (linear < 0) -1.0 else 1.0;
    if (abs_linear <= 0.0031308) {
        return linear * 12.92;
    }
    return sign * (1.055 * powRational(abs_linear, 5, 12) - 0.055);
}

/// sRGB inverse companding: gamma-corrected -> linear
fn srgbLinearize(srgb: f64) f64 {
    const abs_srgb = @abs(srgb);
    const sign: f64 = if (srgb < 0) -1.0 else 1.0;
    if (abs_srgb <= 0.04045) {
        return srgb / 12.92;
    }
    return sign * pow((abs_srgb + 0.055) / 1.055, 12.0 / 5.0);
}

/// A98-RGB transfer function: linear -> gamma
fn a98Gamma(linear: f64) f64 {
    const sign: f64 = if (linear < 0) -1.0 else 1.0;
    return sign * powRational(@abs(linear), 256, 563);
}

/// A98-RGB inverse: gamma -> linear
fn a98Linearize(val: f64) f64 {
    const sign: f64 = if (val < 0) -1.0 else 1.0;
    return sign * powRational(@abs(val), 563, 256);
}

/// ProPhoto-RGB transfer function: linear -> gamma
fn prophotGamma(linear: f64) f64 {
    const abs_val = @abs(linear);
    const sign: f64 = if (linear < 0) -1.0 else 1.0;
    if (abs_val < 1.0 / 512.0) {
        return sign * 16.0 * abs_val;
    }
    return sign * powRational(abs_val, 5, 9);
}

/// ProPhoto-RGB inverse: gamma -> linear
fn prophotLinearize(val: f64) f64 {
    const abs_val = @abs(val);
    const sign: f64 = if (val < 0) -1.0 else 1.0;
    if (abs_val <= 16.0 / 512.0) {
        return sign * abs_val / 16.0;
    }
    return sign * powRational(abs_val, 9, 5);
}

/// Rec2020 transfer function constants
const rec2020_alpha: f64 = 1.09929682680944;
const rec2020_beta: f64 = 0.018053968510807;

/// Rec2020 transfer function: linear -> gamma
fn rec2020Gamma(linear: f64) f64 {
    const abs_val = @abs(linear);
    const sign: f64 = if (linear < 0) -1.0 else 1.0;
    if (abs_val < rec2020_beta) {
        return sign * 4.5 * abs_val;
    }
    return sign * (rec2020_alpha * powRational(abs_val, 9, 20) - (rec2020_alpha - 1.0));
}

/// Rec2020 inverse: gamma -> linear
fn rec2020Linearize(val: f64) f64 {
    const abs_val = @abs(val);
    const sign: f64 = if (val < 0) -1.0 else 1.0;
    if (abs_val < rec2020_beta * 4.5) {
        return sign * abs_val / 4.5;
    }
    return sign * powRational((abs_val + (rec2020_alpha - 1.0)) / rec2020_alpha, 20, 9);
}

// ============================================================================
// Shared RGB byte helpers (0-255 inputs) for builtins and color_format
// ============================================================================

/// Clamp and round a channel to an 8-bit value (CSS hex / legacy RGB formatting).
pub fn clampByte(v: f64) u8 {
    const clamped = std.math.clamp(v, 0.0, 255.0);
    return @intFromFloat(@round(clamped));
}

/// Converts sRGB channels on a 0-255 scale to HSL (hue degrees, S/L as percentages).
pub fn rgb255ToHsl(r_in: f64, g_in: f64, b_in: f64) [3]f64 {
    const rf = r_in / 255.0;
    const gf = g_in / 255.0;
    const bf = b_in / 255.0;
    const cmax = @max(rf, @max(gf, bf));
    const cmin = @min(rf, @min(gf, bf));
    const delta = cmax - cmin;
    const l = (cmax + cmin) / 2.0;
    var h: f64 = 0.0;
    var s: f64 = 0.0;
    if (delta > 0.0) {
        s = delta / (1.0 - @abs(2.0 * l - 1.0));
        if (cmax == rf) {
            h = 60.0 * @mod((gf - bf) / delta, 6.0);
        } else if (cmax == gf) {
            h = 60.0 * ((bf - rf) / delta + 2.0);
        } else {
            h = 60.0 * ((rf - gf) / delta + 4.0);
        }
        if (h < 0.0) h += 360.0;
    }
    return .{ h, s * 100.0, l * 100.0 };
}

// ============================================================================
// Color Space Conversions - Individual Steps
// ============================================================================

// --- sRGB <-> Linear sRGB ---

fn srgbToLinear(rgb: [3]f64) [3]f64 {
    return mapChannels(srgbLinearize, rgb);
}

fn linearToSrgb(linear: [3]f64) [3]f64 {
    return mapChannels(srgbGamma, linear);
}

fn canonicalizeRelativeZero(channels: [3]f64) [3]f64 {
    const max_abs = @max(@abs(channels[0]), @max(@abs(channels[1]), @abs(channels[2])));
    if (max_abs == 0.0 or !std.math.isFinite(max_abs)) return channels;

    const zero_tolerance = max_abs * 1e-15;
    var result = channels;
    for (&result) |*channel| {
        if (@abs(channel.*) <= zero_tolerance) channel.* = 0.0;
    }
    return result;
}

// --- Linear sRGB <-> XYZ-D65 ---

fn linearSrgbToXyzD65(linear: [3]f64) [3]f64 {
    return mulMV(srgb_to_xyz_d65, linear);
}

fn linearSrgbToXyzD50(linear: [3]f64) [3]f64 {
    return mulMV64(srgb_to_xyz_d50, linear);
}

fn xyzD65ToLinearSrgb(xyz: [3]f64) [3]f64 {
    return mulMV(xyz_d65_to_srgb, xyz);
}

fn xyzD50ToLinearSrgbDirect(xyz: [3]f64) [3]f64 {
    return mulMV64(xyz_d50_to_srgb_linear_direct, xyz);
}

// --- HSL <-> sRGB ---

fn hslToSrgb(hsl_val: [3]f64) [3]f64 {
    const h = @mod(hsl_val[0], 360.0);
    const s = hsl_val[1] / 100.0;
    const l = hsl_val[2] / 100.0;

    if (s == 0.0) {
        return .{ l, l, l };
    }

    const a = s * @min(l, 1.0 - l);

    const f = struct {
        fn calc(n: f64, hue: f64, lum: f64, chroma: f64) f64 {
            const k = @mod(n + hue / 30.0, 12.0);
            return lum - chroma * @max(-1.0, @min(@min(k - 3.0, 9.0 - k), 1.0));
        }
    }.calc;

    return .{
        f(0.0, h, l, a),
        f(8.0, h, l, a),
        f(4.0, h, l, a),
    };
}

fn hslToSrgbStandard(hsl_val: [3]f64) [3]f64 {
    const h = @mod(hsl_val[0], 360.0);
    const s = hsl_val[1] / 100.0;
    const l = hsl_val[2] / 100.0;

    if (s == 0.0) return .{ l, l, l };

    const c = (1.0 - @abs(2.0 * l - 1.0)) * s;
    const hp = h / 60.0;
    const m = l - c / 2.0;

    if (hp < 1.0) {
        const x = c * hp;
        return .{ c + m, x + m, m };
    }
    if (hp < 2.0) {
        const x = c * (2.0 - hp);
        return .{ x + m, c + m, m };
    }
    if (hp < 3.0) {
        const x = c * (hp - 2.0);
        return .{ m, c + m, x + m };
    }
    if (hp < 4.0) {
        const x = c * (4.0 - hp);
        return .{ m, x + m, c + m };
    }
    if (hp < 5.0) {
        const x = c * (hp - 4.0);
        return .{ x + m, m, c + m };
    }
    const x = c * (6.0 - hp);
    return .{ c + m, m, x + m };
}

/// 6-case hue formula (degrees) shared by srgbToHsl/srgbToHwb. Caller must
/// guarantee `delta > 0`.
fn hueFromRgb(r: f64, g: f64, b: f64, max_val: f64, delta: f64) f64 {
    const h: f64 = if (max_val == r)
        ((g - b) / delta) + (if (g < b) @as(f64, 6.0) else @as(f64, 0.0))
    else if (max_val == g)
        ((b - r) / delta) + 2.0
    else
        ((r - g) / delta) + 4.0;
    return h * 60.0;
}

fn srgbToHslWithChromaEpsilon(rgb: [3]f64, chroma_threshold: f64) [3]f64 {
    const r = rgb[0];
    const g = rgb[1];
    const b = rgb[2];

    const max_val = @max(r, @max(g, b));
    const min_val = @min(r, @min(g, b));
    const delta = max_val - min_val;
    const l: f64 = (max_val + min_val) / 2.0;
    const epsilon = 1.0 / 100000.0;
    const chroma_epsilon: f64 = if (delta > 0.0 and (l < 0.0 or l > 1.0)) 0.0 else chroma_threshold;

    var h: f64 = 0.0;
    var s: f64 = 0.0;

    if (delta > chroma_epsilon) {
        s = if (l == 0.0 or l == 1.0) blk: {
            break :blk 0.0;
        } else if (l > 0.0 and l < 1.0) blk: {
            const standard = delta / (1.0 - @abs(2.0 * l - 1.0));
            const half_range = (max_val - l) / @min(l, 1.0 - l);
            break :blk if (standard > 1.0 + epsilon) standard else half_range;
        } else blk: {
            break :blk (max_val - l) / @min(l, 1.0 - l);
        };

        h = hueFromRgb(r, g, b, max_val, delta);
    }

    if (s < 0.0) {
        h += 180.0;
        s = @abs(s);
    }

    if (h >= 360.0) {
        h -= 360.0;
    }

    if (delta <= chroma_epsilon or s <= epsilon) {
        h = 0.0;
        s = 0.0;
    }

    return .{ h, s * 100.0, l * 100.0 };
}

fn srgbToHsl(rgb: [3]f64) [3]f64 {
    return srgbToHslWithChromaEpsilon(rgb, 1.0 / 100000.0);
}

// --- HWB <-> sRGB ---

fn hwbToSrgb(hwb_val: [3]f64) [3]f64 {
    var w = hwb_val[1] / 100.0;
    var bk = hwb_val[2] / 100.0;

    // Normalize if w + b > 1
    const sum = w + bk;
    if (sum > 1.0) {
        w /= sum;
        bk /= sum;
    }

    // Start from pure hue
    const rgb = hslToSrgb(.{ hwb_val[0], 100.0, 50.0 });

    return .{
        rgb[0] * (1.0 - w - bk) + w,
        rgb[1] * (1.0 - w - bk) + w,
        rgb[2] * (1.0 - w - bk) + w,
    };
}

fn srgbToHwb(rgb: [3]f64) [3]f64 {
    const r = rgb[0];
    const g = rgb[1];
    const blue = rgb[2];
    const w = @min(rgb[0], @min(rgb[1], rgb[2]));
    const max_channel = @max(rgb[0], @max(rgb[1], rgb[2]));
    const bk = 1.0 - max_channel;
    const w_pct = w * 100.0;
    const bk_pct = 100.0 - max_channel * 100.0;
    const epsilon = 1.0 / 100000.0;
    if (w + bk >= 1.0 - epsilon) return .{ 0.0, w_pct, bk_pct };

    const max_val = max_channel;
    const min_val = @min(r, @min(g, blue));
    const delta = max_val - min_val;
    if (delta <= epsilon) return .{ 0.0, w_pct, bk_pct };

    var hue = hueFromRgb(r, g, blue, max_val, delta);
    if (hue >= 360.0) hue -= 360.0;
    if (hue < 0.0) hue += 360.0;
    return .{ hue, w_pct, bk_pct };
}

// --- Lab <-> XYZ-D50 ---

/// D50 white point
const d50_white: [3]f64 = .{
    0.9642956764295677,
    1.0,
    (1.0 - 0.3457 - 0.3585) / 0.3585,
};

const lab_epsilon: f64 = 216.0 / 24389.0;
const lab_kappa: f64 = 24389.0 / 27.0;

fn labToXyzD50(lab_val: [3]f64) [3]f64 {
    const l = lab_val[0];
    const a = lab_val[1];
    const b = lab_val[2];

    const fy = (l + 16.0) / 116.0;
    const fx = a / 500.0 + fy;
    const fz = fy - b / 200.0;

    const x_r = if (fx * fx * fx > lab_epsilon)
        fx * fx * fx
    else
        (116.0 * fx - 16.0) / lab_kappa;

    const y_r = if (l > lab_kappa * lab_epsilon)
        fy * fy * fy
    else
        l / lab_kappa;

    const z_r = if (fz * fz * fz > lab_epsilon)
        fz * fz * fz
    else
        (116.0 * fz - 16.0) / lab_kappa;

    return .{
        x_r * d50_white[0],
        y_r * d50_white[1],
        z_r * d50_white[2],
    };
}

fn xyzD50ToLab(xyz: [3]f64) [3]f64 {
    const x = xyz[0] / d50_white[0];
    const y = xyz[1] / d50_white[1];
    const z = xyz[2] / d50_white[2];

    const f = struct {
        fn apply(val: f64) f64 {
            if (val > lab_epsilon) {
                return pow(val, 1.0 / 3.0);
            }
            return (lab_kappa * val + 16.0) / 116.0;
        }
    }.apply;

    const fx = f(x);
    const fy = f(y);
    const fz = f(z);

    return .{
        116.0 * fy - 16.0,
        500.0 * (fx - fy),
        200.0 * (fy - fz),
    };
}

// --- LCH <-> Lab ---

fn lchToLab(lch_val: [3]f64) [3]f64 {
    const l = lch_val[0];
    const c = lch_val[1];
    const h = lch_val[2] * math.pi / 180.0;

    return .{
        l,
        c * @cos(h),
        c * @sin(h),
    };
}

/// Apply `|steps|` adjacent-float adjustments toward +inf (steps > 0)
/// or -inf (steps < 0). `steps == 0` is identity. Used to reproduce
/// observed official `sass` CLI rounding for per-route polar
/// coordinate conversions; see the color audit ledger.
fn nextAfterSteps(value: f64, comptime steps: comptime_int) f64 {
    if (steps == 0) return value;
    var v = value;
    const target = if (steps > 0) std.math.inf(f64) else -std.math.inf(f64);
    const n: comptime_int = if (steps > 0) steps else -steps;
    inline for (0..n) |_| {
        v = std.math.nextAfter(f64, v, target);
    }
    return v;
}

/// Generic Lab -> LCH conversion with per-route adjacent-float rounding
/// on the radians-to-degrees coefficient (`deg`) and final hue (`hue`).
/// Each non-zero (deg, hue) pair corresponds to one (source, target)
/// route documented in the color audit ledger and verified by
/// official `sass` CLI clean-room probes. With (0, 0) this is the spec
/// algorithm with no ULP adjustment.
fn labToLchOffset(comptime deg: comptime_int, comptime hue: comptime_int, lab_val: [3]f64) [3]f64 {
    const l = lab_val[0];
    const a = lab_val[1];
    const b = lab_val[2];

    const c = @sqrt(a * a + b * b);
    const degrees_per_rad = nextAfterSteps(180.0 / math.pi, deg);
    var h = math.atan2(b, a) * degrees_per_rad;
    if (h < 0.0) h += 360.0;
    h = nextAfterSteps(h, hue);

    return .{ l, c, h };
}

// --- OKLab <-> XYZ-D65 ---

fn oklabToXyzD65(oklab_val: [3]f64) [3]f64 {
    // OKLab -> LMS (cube root)
    const lms_cbrt = mulMV64(oklab_to_lms_cbrt, oklab_val);
    // Cube to get LMS
    const lms: [3]f64 = .{
        lms_cbrt[0] * lms_cbrt[0] * lms_cbrt[0],
        lms_cbrt[1] * lms_cbrt[1] * lms_cbrt[1],
        lms_cbrt[2] * lms_cbrt[2] * lms_cbrt[2],
    };
    // LMS -> XYZ-D65
    return mulMV64(lms_to_xyz_d65, lms);
}

fn oklabToLinearDisplayP3Direct(oklab_val: [3]f64) [3]f64 {
    const lms_cbrt = mulMV64(oklab_to_lms_cbrt, oklab_val);
    const lms: [3]f64 = .{
        lms_cbrt[0] * lms_cbrt[0] * lms_cbrt[0],
        lms_cbrt[1] * lms_cbrt[1] * lms_cbrt[1],
        lms_cbrt[2] * lms_cbrt[2] * lms_cbrt[2],
    };
    return mulMV64(lms_to_display_p3_linear, lms);
}

fn oklabToXyzD50Direct(oklab_val: [3]f64) [3]f64 {
    const lms_cbrt = mulMV64(oklab_to_lms_cbrt, oklab_val);
    const lms: [3]f64 = .{
        lms_cbrt[0] * lms_cbrt[0] * lms_cbrt[0],
        lms_cbrt[1] * lms_cbrt[1] * lms_cbrt[1],
        lms_cbrt[2] * lms_cbrt[2] * lms_cbrt[2],
    };
    return mulMV64(lms_to_xyz_d50_direct, lms);
}

fn oklabToLinearProphotoDirect(oklab_val: [3]f64) [3]f64 {
    const lms_cbrt = mulMV64(oklab_to_lms_cbrt, oklab_val);
    const lms: [3]f64 = .{
        lms_cbrt[0] * lms_cbrt[0] * lms_cbrt[0],
        lms_cbrt[1] * lms_cbrt[1] * lms_cbrt[1],
        lms_cbrt[2] * lms_cbrt[2] * lms_cbrt[2],
    };
    return mulMV64(lms_to_prophoto_linear_direct, lms);
}

fn oklabToLinearA98Direct(oklab_val: [3]f64) [3]f64 {
    const lms_cbrt = mulMV64(oklab_to_lms_cbrt, oklab_val);
    const lms: [3]f64 = .{
        lms_cbrt[0] * lms_cbrt[0] * lms_cbrt[0],
        lms_cbrt[1] * lms_cbrt[1] * lms_cbrt[1],
        lms_cbrt[2] * lms_cbrt[2] * lms_cbrt[2],
    };
    return mulMV64(lms_to_a98_linear_direct, lms);
}

fn oklabToXyzD65Extended(oklab_val: [3]f64) [3]f64 {
    const lms_cbrt = mulMV(oklab_to_lms_cbrt, oklab_val);
    const lms: [3]f64 = .{
        lms_cbrt[0] * lms_cbrt[0] * lms_cbrt[0],
        lms_cbrt[1] * lms_cbrt[1] * lms_cbrt[1],
        lms_cbrt[2] * lms_cbrt[2] * lms_cbrt[2],
    };
    return mulMV(lms_to_xyz_d65, lms);
}

fn xyzD65ToOklab(xyz: [3]f64) [3]f64 {
    // XYZ-D65 -> LMS
    const lms = mulMV64(xyz_d65_to_lms, xyz);
    // Cube root
    const lms_cbrt: [3]f64 = .{
        signedPowCbrt(lms[0]),
        signedPowCbrt(lms[1]),
        signedPowCbrt(lms[2]),
    };
    // LMS^(1/3) -> OKLab
    return mulMV64(lms_cbrt_to_oklab, lms_cbrt);
}

fn linearSrgbToOklab(linear: [3]f64) [3]f64 {
    const lms = mulMV64(linear_srgb_to_lms, linear);
    const lms_cbrt: [3]f64 = .{
        signedPowCbrt(lms[0]),
        signedPowCbrt(lms[1]),
        signedPowCbrt(lms[2]),
    };
    return mulMV64(lms_cbrt_to_oklab, lms_cbrt);
}

fn oklabToLinearSrgb(oklab_val: [3]f64) [3]f64 {
    const lms_cbrt = mulMV64(oklab_to_lms_cbrt, oklab_val);
    const lms: [3]f64 = .{
        lms_cbrt[0] * lms_cbrt[0] * lms_cbrt[0],
        lms_cbrt[1] * lms_cbrt[1] * lms_cbrt[1],
        lms_cbrt[2] * lms_cbrt[2] * lms_cbrt[2],
    };
    return mulMV64(lms_to_linear_srgb, lms);
}

// --- OKLCH <-> OKLab ---

fn oklchToOklab(oklch_val: [3]f64) [3]f64 {
    const l = oklch_val[0];
    const c = oklch_val[1];
    const h = oklch_val[2] * math.pi / 180.0;

    return .{
        l,
        c * @cos(h),
        c * @sin(h),
    };
}

fn oklabToOklch(oklab_val: [3]f64) [3]f64 {
    const l = oklab_val[0];
    const a = oklab_val[1];
    const b = oklab_val[2];

    const c = @sqrt(a * a + b * b);
    var h: f64 = @floatCast(@as(f80, @floatCast(math.atan2(b, a))) * 180.0 / @as(f80, @floatCast(math.pi)));
    if (h < 0.0) h += 360.0;

    return .{ l, c, h };
}

/// Binary64-only OKLab -> OKLCh conversion with per-route adjacent-float
/// rounding on the radians-to-degrees coefficient and final hue. Distinct
/// from `oklabToOklch`, which uses an f80 intermediate for the generic
/// path. Each non-zero (deg, hue) pair documents an observed sass CLI
/// route — see the color audit ledger.
fn oklabToOklchBinary64Offset(comptime deg: comptime_int, comptime hue: comptime_int, oklab_val: [3]f64) [3]f64 {
    const l = oklab_val[0];
    const a = oklab_val[1];
    const b = oklab_val[2];

    const c = @sqrt(a * a + b * b);
    const degrees_per_rad = nextAfterSteps(180.0 / math.pi, deg);
    var h = math.atan2(b, a) * degrees_per_rad;
    if (h < 0.0) h += 360.0;
    h = nextAfterSteps(h, hue);

    return .{ l, c, h };
}

// --- XYZ-D50 <-> XYZ-D65 ---

fn xyzD50ToD65(xyz_d50: [3]f64) [3]f64 {
    return mulMV64(d50_to_d65, xyz_d50);
}

fn xyzD50ToD65OklabRoute(xyz_d50: [3]f64) [3]f64 {
    const m: Matrix3 = .{
        .{ std.math.nextAfter(f64, std.math.nextAfter(f64, 0.95547342148807520, -std.math.inf(f64)), -std.math.inf(f64)), -0.02309845494876452, 0.06325924320057065 },
        .{ -0.02836970933386358, 1.00999539808130410, 0.021041441191917303 },
        .{ 0.01231401486448199, -0.02050764929889898, 1.33036592624212400 },
    };
    return mulMV64(m, xyz_d50);
}

fn xyzD65ToD50(xyz_d65: [3]f64) [3]f64 {
    return mulMV64(d65_to_d50, xyz_d65);
}

// --- Display-P3 <-> Linear Display-P3 <-> XYZ-D65 ---
// Display-P3 uses the same sRGB transfer function.

fn displayP3ToLinear(rgb: [3]f64) [3]f64 {
    return srgbToLinear(rgb);
}

fn linearToDisplayP3(linear: [3]f64) [3]f64 {
    return linearToSrgb(linear);
}

fn linearDisplayP3ToXyzD65(linear: [3]f64) [3]f64 {
    return mulMV(display_p3_to_xyz_d65, linear);
}

fn linearDisplayP3ToXyzD50(linear: [3]f64) [3]f64 {
    return mulMV64(display_p3_to_xyz_d50, linear);
}

fn xyzD65ToLinearDisplayP3(xyz: [3]f64) [3]f64 {
    return mulMV64(xyz_d65_to_display_p3, xyz);
}

fn xyzD65ToLinearDisplayP3Direct(xyz: [3]f64) [3]f64 {
    return mulMV64(xyz_d65_to_display_p3_direct, xyz);
}

fn xyzD65ToLinearDisplayP3FromLch(xyz: [3]f64) [3]f64 {
    return mulMV64(xyz_d65_to_display_p3_from_lch, xyz);
}

fn linearDisplayP3ToLinearSrgb(linear: [3]f64) [3]f64 {
    return mulMV64(display_p3_to_srgb_linear, linear);
}

fn linearSrgbToLinearDisplayP3(linear: [3]f64) [3]f64 {
    return mulMV64(srgb_to_display_p3_linear, linear);
}

fn linearSrgbToLinearProphoto(linear: [3]f64) [3]f64 {
    return mulMV64(srgb_to_prophoto_linear, linear);
}

fn linearSrgbToLinearRec2020(linear: [3]f64) [3]f64 {
    return mulMV64(srgb_to_rec2020_linear, linear);
}

// --- A98-RGB ---

fn a98ToLinear(rgb: [3]f64) [3]f64 {
    return mapChannels(a98Linearize, rgb);
}

fn linearToA98(linear: [3]f64) [3]f64 {
    return mapChannels(a98Gamma, linear);
}

fn linearA98ToXyzD65(linear: [3]f64) [3]f64 {
    return mulMV(a98_rgb_to_xyz_d65, linear);
}

fn linearA98ToXyzD50(linear: [3]f64) [3]f64 {
    return mulMV64(a98_rgb_to_xyz_d50, linear);
}

fn xyzD65ToLinearA98(xyz: [3]f64) [3]f64 {
    return mulMV64(xyz_d65_to_a98_rgb, xyz);
}

fn linearA98ToLinearDisplayP3(linear: [3]f64) [3]f64 {
    return mulMV64(a98_rgb_to_display_p3_linear, linear);
}

fn linearA98ToLinearProphoto(linear: [3]f64) [3]f64 {
    return mulMV64(a98_rgb_to_prophoto_linear, linear);
}

fn linearDisplayP3ToLinearA98(linear: [3]f64) [3]f64 {
    return mulMV64(display_p3_to_a98_rgb_linear, linear);
}

// --- ProPhoto-RGB ---

fn prophotoToLinear(rgb: [3]f64) [3]f64 {
    return mapChannels(prophotLinearize, rgb);
}

fn linearToProphoto(linear: [3]f64) [3]f64 {
    return mapChannels(prophotGamma, linear);
}

fn linearProphotoToXyzD50(linear: [3]f64) [3]f64 {
    return mulMV(prophoto_to_xyz_d50, linear);
}

fn linearProphotoToXyzD65(linear: [3]f64) [3]f64 {
    return mulMV64(prophoto_to_xyz_d65, linear);
}

fn xyzD50ToLinearProphoto(xyz: [3]f64) [3]f64 {
    return mulMV(xyz_d50_to_prophoto, xyz);
}

fn linearProphotoToLinearSrgb(linear: [3]f64) [3]f64 {
    return mulMV64(prophoto_to_srgb_linear, linear);
}

fn linearProphotoToLinearDisplayP3(linear: [3]f64) [3]f64 {
    return mulMV64(prophoto_to_display_p3_linear, linear);
}

fn linearDisplayP3ToLinearProphoto(linear: [3]f64) [3]f64 {
    return mulMV64(display_p3_to_prophoto_linear, linear);
}

fn linearDisplayP3ToLinearRec2020(linear: [3]f64) [3]f64 {
    return mulMV64(display_p3_to_rec2020_linear, linear);
}

// --- Rec2020 ---

fn rec2020ToLinear(rgb: [3]f64) [3]f64 {
    return mapChannels(rec2020Linearize, rgb);
}

fn linearToRec2020(linear: [3]f64) [3]f64 {
    return mapChannels(rec2020Gamma, linear);
}

fn linearRec2020ToXyzD65(linear: [3]f64) [3]f64 {
    return mulMV(rec2020_to_xyz_d65, linear);
}

fn linearRec2020ToXyzD50(linear: [3]f64) [3]f64 {
    return mulMV64(rec2020_to_xyz_d50, linear);
}

fn xyzD65ToLinearRec2020(xyz: [3]f64) [3]f64 {
    return mulMV(xyz_d65_to_rec2020, xyz);
}

fn linearRec2020ToLinearSrgb(linear: [3]f64) [3]f64 {
    return mulMV64(rec2020_to_srgb_linear, linear);
}

fn linearRec2020ToLinearDisplayP3(linear: [3]f64) [3]f64 {
    return mulMV64(rec2020_to_display_p3_linear, linear);
}

fn linearRec2020ToLinearProphoto(linear: [3]f64) [3]f64 {
    return mulMV64(rec2020_to_prophoto_linear, linear);
}

// ============================================================================
// To / From XYZ-D65 Hub
// ============================================================================

/// Convert any color space to XYZ-D65.
fn toXyzD65(channels: [3]f64, space: ColorSpace) [3]f64 {
    return switch (space) {
        .xyz_d65 => channels,
        .xyz_d50 => xyzD50ToD65(channels),
        .srgb_linear => linearSrgbToXyzD65(channels),
        .srgb => linearSrgbToXyzD65(srgbToLinear(channels)),
        .hsl => linearSrgbToXyzD65(srgbToLinear(hslToSrgbStandard(channels))),
        .hwb => linearSrgbToXyzD65(srgbToLinear(hwbToSrgb(channels))),
        .lab => xyzD50ToD65(labToXyzD50(channels)),
        .lch => xyzD50ToD65(labToXyzD50(lchToLab(channels))),
        .oklab => oklabToXyzD65(channels),
        .oklch => oklabToXyzD65(oklchToOklab(channels)),
        .display_p3 => linearDisplayP3ToXyzD65(displayP3ToLinear(channels)),
        .display_p3_linear => linearDisplayP3ToXyzD65(channels),
        .a98_rgb => linearA98ToXyzD65(a98ToLinear(channels)),
        .prophoto_rgb => linearProphotoToXyzD65(prophotoToLinear(channels)),
        .rec2020 => linearRec2020ToXyzD65(rec2020ToLinear(channels)),
    };
}

/// Convert from XYZ-D65 to any color space.
fn fromXyzD65(xyz: [3]f64, space: ColorSpace) [3]f64 {
    return switch (space) {
        .xyz_d65 => xyz,
        .xyz_d50 => xyzD65ToD50(xyz),
        .srgb_linear => canonicalizeRelativeZero(xyzD65ToLinearSrgb(xyz)),
        .srgb => canonicalizeRelativeZero(linearToSrgb(canonicalizeRelativeZero(xyzD65ToLinearSrgb(xyz)))),
        .hsl => srgbToHsl(canonicalizeRelativeZero(linearToSrgb(canonicalizeRelativeZero(xyzD65ToLinearSrgb(xyz))))),
        .hwb => srgbToHwb(canonicalizeRelativeZero(linearToSrgb(canonicalizeRelativeZero(xyzD65ToLinearSrgb(xyz))))),
        .lab => xyzD50ToLab(xyzD65ToD50(xyz)),
        .lch => labToLchOffset(2, 0, xyzD50ToLab(xyzD65ToD50(xyz))),
        .oklab => xyzD65ToOklab(xyz),
        .oklch => oklabToOklch(xyzD65ToOklab(xyz)),
        .display_p3 => canonicalizeRelativeZero(linearToDisplayP3(canonicalizeRelativeZero(xyzD65ToLinearDisplayP3(xyz)))),
        .display_p3_linear => canonicalizeRelativeZero(xyzD65ToLinearDisplayP3(xyz)),
        .a98_rgb => canonicalizeRelativeZero(linearToA98(canonicalizeRelativeZero(xyzD65ToLinearA98(xyz)))),
        .prophoto_rgb => canonicalizeRelativeZero(linearToProphoto(canonicalizeRelativeZero(xyzD50ToLinearProphoto(xyzD65ToD50(xyz))))),
        .rec2020 => canonicalizeRelativeZero(linearToRec2020(canonicalizeRelativeZero(xyzD65ToLinearRec2020(xyz)))),
    };
}

// ============================================================================
// Public API
// ============================================================================

/// Returns true if this space natively uses D50 (avoids D50<->D65 round-trip).
fn usesD50(space: ColorSpace) bool {
    return switch (space) {
        .lab, .lch, .xyz_d50, .prophoto_rgb => true,
        else => false,
    };
}

/// Convert to XYZ-D50 (for D50-native spaces).
fn toXyzD50(channels: [3]f64, space: ColorSpace) [3]f64 {
    return switch (space) {
        .xyz_d50 => channels,
        .lab => labToXyzD50(channels),
        .lch => labToXyzD50(lchToLab(channels)),
        .prophoto_rgb => linearProphotoToXyzD50(prophotoToLinear(channels)),
        .srgb_linear => linearSrgbToXyzD50(channels),
        .srgb => linearSrgbToXyzD50(srgbToLinear(channels)),
        .hsl => linearSrgbToXyzD50(srgbToLinear(hslToSrgbStandard(channels))),
        .hwb => linearSrgbToXyzD50(srgbToLinear(hwbToSrgb(channels))),
        .display_p3_linear => linearDisplayP3ToXyzD50(channels),
        .display_p3 => linearDisplayP3ToXyzD50(displayP3ToLinear(channels)),
        .a98_rgb => linearA98ToXyzD50(a98ToLinear(channels)),
        .rec2020 => linearRec2020ToXyzD50(rec2020ToLinear(channels)),
        else => xyzD65ToD50(toXyzD65(channels, space)),
    };
}

/// Convert from XYZ-D50 to a D50-native space.
fn fromXyzD50(xyz: [3]f64, space: ColorSpace) [3]f64 {
    return switch (space) {
        .xyz_d50 => xyz,
        .lab => xyzD50ToLab(xyz),
        .lch => labToLchOffset(2, 0, xyzD50ToLab(xyz)),
        .prophoto_rgb => linearToProphoto(xyzD50ToLinearProphoto(xyz)),
        else => unreachable,
    };
}

/// Convert a color from one color space to another.
///
/// Routes through XYZ-D65 as the hub, with shortcuts for D50-native
/// spaces to avoid unnecessary D50<->D65 chromatic adaptation
/// round-trips. Per-(source, target) pairs use helpers with explicit
/// suffixes:
/// - `*Direct` / `*Route`: direct matrix shortcut for one (source,
///   target) pair, derived from official `sass` CLI clean-room probes.
/// - `*Offset(deg, hue, ...)`: polar coordinate conversion with `deg`
///   adjacent-float steps applied to `180/pi` and `hue` adjacent-float
///   steps applied to the final hue.
/// - `*FromLch`, `*Extended`: variant matrices/accumulators used only
///   when the source path is LCH or when extended-precision OKLab
///   accumulation matches the CLI's direct route.
///
/// Each non-generic arm corresponds to one row in
/// the color audit ledger (classification:
/// `spec` or `sass-cli-observed`). No arm is keyed on package, fixture,
/// or numeric input value.
pub fn convert(color: Color, target: ColorSpace) Color {
    if (color.space == target) return color;

    const channels: [3]f64 = .{ color.channels[0], color.channels[1], color.channels[2] };

    switch (color.space) {
        .xyz_d50 => switch (target) {
            .oklab => {
                const oklab = xyzD65ToOklab(xyzD50ToD65OklabRoute(channels));
                return Color.init(oklab[0], oklab[1], oklab[2], color.channels[3], .oklab);
            },
            .oklch => {
                const oklch = oklabToOklch(xyzD65ToOklab(xyzD50ToD65OklabRoute(channels)));
                return Color.init(oklch[0], oklch[1], oklch[2], color.channels[3], .oklch);
            },
            else => {},
        },
        .xyz_d65 => switch (target) {
            .lch => {
                const lch = labToLchOffset(0, 0, xyzD50ToLab(xyzD65ToD50(channels)));
                return Color.init(lch[0], lch[1], lch[2], color.channels[3], .lch);
            },
            .oklch => {
                const oklch = oklabToOklch(xyzD65ToOklab(channels));
                const hue = std.math.nextAfter(f64, std.math.nextAfter(f64, oklch[2], -std.math.inf(f64)), -std.math.inf(f64));
                return Color.init(oklch[0], oklch[1], hue, color.channels[3], .oklch);
            },
            else => {},
        },
        .srgb => switch (target) {
            .srgb_linear => {
                const linear = srgbToLinear(channels);
                return Color.init(linear[0], linear[1], linear[2], color.channels[3], .srgb_linear);
            },
            .hsl => {
                const hsl = srgbToHsl(channels);
                return Color.init(hsl[0], hsl[1], hsl[2], color.channels[3], .hsl);
            },
            .hwb => {
                const hwb = srgbToHwb(channels);
                return Color.init(hwb[0], hwb[1], hwb[2], color.channels[3], .hwb);
            },
            .display_p3_linear => {
                const linear = linearSrgbToLinearDisplayP3(srgbToLinear(channels));
                return Color.init(linear[0], linear[1], linear[2], color.channels[3], .display_p3_linear);
            },
            .display_p3 => {
                const p3 = linearToDisplayP3(linearSrgbToLinearDisplayP3(srgbToLinear(channels)));
                return Color.init(p3[0], p3[1], p3[2], color.channels[3], .display_p3);
            },
            .prophoto_rgb => {
                const prophoto = linearToProphoto(linearSrgbToLinearProphoto(srgbToLinear(channels)));
                return Color.init(prophoto[0], prophoto[1], prophoto[2], color.channels[3], .prophoto_rgb);
            },
            .rec2020 => {
                const rec2020 = linearToRec2020(linearSrgbToLinearRec2020(srgbToLinear(channels)));
                return Color.init(rec2020[0], rec2020[1], rec2020[2], color.channels[3], .rec2020);
            },
            .oklab => {
                const oklab = linearSrgbToOklab(srgbToLinear(channels));
                return Color.init(oklab[0], oklab[1], oklab[2], color.channels[3], .oklab);
            },
            .oklch => {
                const oklch = oklabToOklch(linearSrgbToOklab(srgbToLinear(channels)));
                return Color.init(oklch[0], oklch[1], oklch[2], color.channels[3], .oklch);
            },
            else => {},
        },
        .srgb_linear => switch (target) {
            .srgb => {
                const srgb = linearToSrgb(channels);
                return Color.init(srgb[0], srgb[1], srgb[2], color.channels[3], .srgb);
            },
            .hsl => {
                const hsl = srgbToHsl(linearToSrgb(channels));
                return Color.init(hsl[0], hsl[1], hsl[2], color.channels[3], .hsl);
            },
            .hwb => {
                const hwb = srgbToHwb(linearToSrgb(channels));
                return Color.init(hwb[0], hwb[1], hwb[2], color.channels[3], .hwb);
            },
            .display_p3_linear => {
                const linear = linearSrgbToLinearDisplayP3(channels);
                return Color.init(linear[0], linear[1], linear[2], color.channels[3], .display_p3_linear);
            },
            .display_p3 => {
                const p3 = linearToDisplayP3(linearSrgbToLinearDisplayP3(channels));
                return Color.init(p3[0], p3[1], p3[2], color.channels[3], .display_p3);
            },
            .oklab => {
                const oklab = linearSrgbToOklab(channels);
                return Color.init(oklab[0], oklab[1], oklab[2], color.channels[3], .oklab);
            },
            .oklch => {
                const oklch = oklabToOklchBinary64Offset(2, 0, linearSrgbToOklab(channels));
                return Color.init(oklch[0], oklch[1], oklch[2], color.channels[3], .oklch);
            },
            else => {},
        },
        .hsl => switch (target) {
            .srgb => {
                const srgb = hslToSrgbStandard(channels);
                return Color.init(srgb[0], srgb[1], srgb[2], color.channels[3], .srgb);
            },
            .srgb_linear => {
                const linear = srgbToLinear(hslToSrgbStandard(channels));
                return Color.init(linear[0], linear[1], linear[2], color.channels[3], .srgb_linear);
            },
            .hwb => {
                const srgb = hslToSrgbStandard(channels);
                const hwb = srgbToHwb(srgb);
                return Color.init(hwb[0], hwb[1], hwb[2], color.channels[3], .hwb);
            },
            .display_p3_linear => {
                const linear = linearSrgbToLinearDisplayP3(srgbToLinear(hslToSrgbStandard(channels)));
                return Color.init(linear[0], linear[1], linear[2], color.channels[3], .display_p3_linear);
            },
            .xyz_d65 => {
                const xyz = mulMV64(srgb_to_xyz_d65, srgbToLinear(hslToSrgbStandard(channels)));
                return Color.init(xyz[0], xyz[1], xyz[2], color.channels[3], .xyz_d65);
            },
            .lch => {
                const lch = labToLchOffset(-1, 0, xyzD50ToLab(linearSrgbToXyzD50(srgbToLinear(hslToSrgbStandard(channels)))));
                return Color.init(lch[0], lch[1], lch[2], color.channels[3], .lch);
            },
            else => {},
        },
        .hwb => switch (target) {
            .srgb => {
                const srgb = hwbToSrgb(channels);
                return Color.init(srgb[0], srgb[1], srgb[2], color.channels[3], .srgb);
            },
            .srgb_linear => {
                const linear = srgbToLinear(hwbToSrgb(channels));
                return Color.init(linear[0], linear[1], linear[2], color.channels[3], .srgb_linear);
            },
            .display_p3_linear => {
                const linear = linearSrgbToLinearDisplayP3(srgbToLinear(hwbToSrgb(channels)));
                return Color.init(linear[0], linear[1], linear[2], color.channels[3], .display_p3_linear);
            },
            .hsl => {
                const srgb = hwbToSrgb(channels);
                const hsl = srgbToHsl(srgb);
                return Color.init(hsl[0], hsl[1], hsl[2], color.channels[3], .hsl);
            },
            else => {},
        },
        .a98_rgb => switch (target) {
            .oklch => {
                const oklch = oklabToOklchBinary64Offset(2, 0, xyzD65ToOklab(linearA98ToXyzD65(a98ToLinear(channels))));
                return Color.init(oklch[0], oklch[1], oklch[2], color.channels[3], .oklch);
            },
            .display_p3_linear => {
                const linear = linearA98ToLinearDisplayP3(a98ToLinear(channels));
                return Color.init(linear[0], linear[1], linear[2], color.channels[3], .display_p3_linear);
            },
            .display_p3 => {
                const p3 = linearToDisplayP3(linearA98ToLinearDisplayP3(a98ToLinear(channels)));
                return Color.init(p3[0], p3[1], p3[2], color.channels[3], .display_p3);
            },
            .prophoto_rgb => {
                const prophoto = linearToProphoto(linearA98ToLinearProphoto(a98ToLinear(channels)));
                return Color.init(prophoto[0], prophoto[1], prophoto[2], color.channels[3], .prophoto_rgb);
            },
            else => {},
        },
        .display_p3 => switch (target) {
            .display_p3_linear => {
                const linear = displayP3ToLinear(channels);
                return Color.init(linear[0], linear[1], linear[2], color.channels[3], .display_p3_linear);
            },
            .srgb_linear => {
                const linear = linearDisplayP3ToLinearSrgb(displayP3ToLinear(channels));
                return Color.init(linear[0], linear[1], linear[2], color.channels[3], .srgb_linear);
            },
            .srgb => {
                const srgb = linearToSrgb(linearDisplayP3ToLinearSrgb(displayP3ToLinear(channels)));
                return Color.init(srgb[0], srgb[1], srgb[2], color.channels[3], .srgb);
            },
            .hsl => {
                const hsl = srgbToHsl(linearToSrgb(linearDisplayP3ToLinearSrgb(displayP3ToLinear(channels))));
                return Color.init(hsl[0], hsl[1], hsl[2], color.channels[3], .hsl);
            },
            .hwb => {
                const hwb = srgbToHwb(linearToSrgb(linearDisplayP3ToLinearSrgb(displayP3ToLinear(channels))));
                return Color.init(hwb[0], hwb[1], hwb[2], color.channels[3], .hwb);
            },
            .a98_rgb => {
                const a98 = linearToA98(linearDisplayP3ToLinearA98(displayP3ToLinear(channels)));
                return Color.init(a98[0], a98[1], a98[2], color.channels[3], .a98_rgb);
            },
            .prophoto_rgb => {
                const prophoto = linearToProphoto(linearDisplayP3ToLinearProphoto(displayP3ToLinear(channels)));
                return Color.init(prophoto[0], prophoto[1], prophoto[2], color.channels[3], .prophoto_rgb);
            },
            .rec2020 => {
                const rec2020 = linearToRec2020(linearDisplayP3ToLinearRec2020(displayP3ToLinear(channels)));
                return Color.init(rec2020[0], rec2020[1], rec2020[2], color.channels[3], .rec2020);
            },
            .lch => {
                const lch = labToLchOffset(4, 0, xyzD50ToLab(linearDisplayP3ToXyzD50(displayP3ToLinear(channels))));
                return Color.init(lch[0], lch[1], lch[2], color.channels[3], .lch);
            },
            else => {},
        },
        .display_p3_linear => switch (target) {
            .display_p3 => {
                const p3 = linearToDisplayP3(channels);
                return Color.init(p3[0], p3[1], p3[2], color.channels[3], .display_p3);
            },
            .srgb_linear => {
                const linear = linearDisplayP3ToLinearSrgb(channels);
                return Color.init(linear[0], linear[1], linear[2], color.channels[3], .srgb_linear);
            },
            .srgb => {
                const srgb = linearToSrgb(linearDisplayP3ToLinearSrgb(channels));
                return Color.init(srgb[0], srgb[1], srgb[2], color.channels[3], .srgb);
            },
            .hsl => {
                const hsl = srgbToHsl(linearToSrgb(linearDisplayP3ToLinearSrgb(channels)));
                return Color.init(hsl[0], hsl[1], hsl[2], color.channels[3], .hsl);
            },
            .hwb => {
                const hwb = srgbToHwb(linearToSrgb(linearDisplayP3ToLinearSrgb(channels)));
                return Color.init(hwb[0], hwb[1], hwb[2], color.channels[3], .hwb);
            },
            .oklch => {
                const oklch = oklabToOklchBinary64Offset(2, 0, xyzD65ToOklab(linearDisplayP3ToXyzD65(channels)));
                return Color.init(oklch[0], oklch[1], oklch[2], color.channels[3], .oklch);
            },
            else => {},
        },
        .rec2020 => switch (target) {
            .srgb_linear => {
                const linear = linearRec2020ToLinearSrgb(rec2020ToLinear(channels));
                return Color.init(linear[0], linear[1], linear[2], color.channels[3], .srgb_linear);
            },
            .srgb => {
                const srgb = linearToSrgb(linearRec2020ToLinearSrgb(rec2020ToLinear(channels)));
                return Color.init(srgb[0], srgb[1], srgb[2], color.channels[3], .srgb);
            },
            .display_p3_linear => {
                const linear = linearRec2020ToLinearDisplayP3(rec2020ToLinear(channels));
                return Color.init(linear[0], linear[1], linear[2], color.channels[3], .display_p3_linear);
            },
            .display_p3 => {
                const p3 = linearToDisplayP3(linearRec2020ToLinearDisplayP3(rec2020ToLinear(channels)));
                return Color.init(p3[0], p3[1], p3[2], color.channels[3], .display_p3);
            },
            .prophoto_rgb => {
                const prophoto = linearToProphoto(linearRec2020ToLinearProphoto(rec2020ToLinear(channels)));
                return Color.init(prophoto[0], prophoto[1], prophoto[2], color.channels[3], .prophoto_rgb);
            },
            .lch => {
                const lch = labToLchOffset(2, 4, xyzD50ToLab(linearRec2020ToXyzD50(rec2020ToLinear(channels))));
                return Color.init(lch[0], lch[1], lch[2], color.channels[3], .lch);
            },
            else => {},
        },
        .prophoto_rgb => switch (target) {
            .srgb_linear => {
                const linear = linearProphotoToLinearSrgb(prophotoToLinear(channels));
                return Color.init(linear[0], linear[1], linear[2], color.channels[3], .srgb_linear);
            },
            .srgb => {
                const srgb = linearToSrgb(linearProphotoToLinearSrgb(prophotoToLinear(channels)));
                return Color.init(srgb[0], srgb[1], srgb[2], color.channels[3], .srgb);
            },
            .display_p3_linear => {
                const linear = linearProphotoToLinearDisplayP3(prophotoToLinear(channels));
                return Color.init(linear[0], linear[1], linear[2], color.channels[3], .display_p3_linear);
            },
            .display_p3 => {
                const p3 = linearToDisplayP3(linearProphotoToLinearDisplayP3(prophotoToLinear(channels)));
                return Color.init(p3[0], p3[1], p3[2], color.channels[3], .display_p3);
            },
            .hsl => {
                const xyz = linearProphotoToXyzD65(prophotoToLinear(channels));
                const srgb = canonicalizeRelativeZero(linearToSrgb(canonicalizeRelativeZero(xyzD65ToLinearSrgb(xyz))));
                const hsl = srgbToHslWithChromaEpsilon(srgb, 0.0);
                return Color.init(hsl[0], hsl[1], hsl[2], color.channels[3], .hsl);
            },
            .lch => {
                const lch = labToLchOffset(3, 0, xyzD50ToLab(linearProphotoToXyzD50(prophotoToLinear(channels))));
                return Color.init(lch[0], lch[1], lch[2], color.channels[3], .lch);
            },
            .oklab => {
                const oklab = xyzD65ToOklab(xyzD50ToD65(linearProphotoToXyzD50(prophotoToLinear(channels))));
                return Color.init(oklab[0], oklab[1], oklab[2], color.channels[3], .oklab);
            },
            .oklch => {
                const oklch = oklabToOklch(xyzD65ToOklab(xyzD50ToD65(linearProphotoToXyzD50(prophotoToLinear(channels)))));
                const hue = std.math.nextAfter(f64, oklch[2], std.math.inf(f64));
                return Color.init(oklch[0], oklch[1], hue, color.channels[3], .oklch);
            },
            else => {},
        },
        .oklab => switch (target) {
            .srgb_linear => {
                const linear = oklabToLinearSrgb(channels);
                return Color.init(linear[0], linear[1], linear[2], color.channels[3], .srgb_linear);
            },
            .srgb => {
                const srgb = linearToSrgb(oklabToLinearSrgb(channels));
                return Color.init(srgb[0], srgb[1], srgb[2], color.channels[3], .srgb);
            },
            .hsl => {
                const hsl = srgbToHsl(linearToSrgb(oklabToLinearSrgb(channels)));
                return Color.init(hsl[0], hsl[1], hsl[2], color.channels[3], .hsl);
            },
            .display_p3_linear => {
                const linear = oklabToLinearDisplayP3Direct(channels);
                return Color.init(linear[0], linear[1], linear[2], color.channels[3], .display_p3_linear);
            },
            .xyz_d50 => {
                const xyz = oklabToXyzD50Direct(channels);
                return Color.init(xyz[0], xyz[1], xyz[2], color.channels[3], .xyz_d50);
            },
            .lab => {
                const lab = xyzD50ToLab(oklabToXyzD50Direct(channels));
                return Color.init(lab[0], lab[1], lab[2], color.channels[3], .lab);
            },
            .lch => {
                const lch = labToLchOffset(2, 0, xyzD50ToLab(oklabToXyzD50Direct(channels)));
                return Color.init(lch[0], lch[1], lch[2], color.channels[3], .lch);
            },
            .oklch => {
                const oklch = oklabToOklch(channels);
                return Color.init(oklch[0], oklch[1], oklch[2], color.channels[3], .oklch);
            },
            else => {},
        },
        .lch => switch (target) {
            .lab => {
                const lab = lchToLab(channels);
                return Color.init(lab[0], lab[1], lab[2], color.channels[3], .lab);
            },
            .srgb_linear => {
                const linear = xyzD50ToLinearSrgbDirect(labToXyzD50(lchToLab(channels)));
                return Color.init(linear[0], linear[1], linear[2], color.channels[3], .srgb_linear);
            },
            .display_p3_linear => {
                const linear = xyzD65ToLinearDisplayP3FromLch(xyzD50ToD65(labToXyzD50(lchToLab(channels))));
                return Color.init(linear[0], linear[1], linear[2], color.channels[3], .display_p3_linear);
            },
            else => {},
        },
        .oklch => switch (target) {
            .oklab => {
                const oklab = xyzD65ToOklab(oklabToXyzD65Extended(oklchToOklab(channels)));
                return Color.init(oklab[0], oklab[1], oklab[2], color.channels[3], .oklab);
            },
            .lab => {
                const lab = xyzD50ToLab(oklabToXyzD50Direct(oklchToOklab(channels)));
                return Color.init(lab[0], lab[1], lab[2], color.channels[3], .lab);
            },
            .lch => {
                const lch = labToLchOffset(-5, 0, xyzD50ToLab(oklabToXyzD50Direct(oklchToOklab(channels))));
                return Color.init(lch[0], lch[1], lch[2], color.channels[3], .lch);
            },
            .srgb_linear => {
                const linear = oklabToLinearSrgb(oklchToOklab(channels));
                return Color.init(linear[0], linear[1], linear[2], color.channels[3], .srgb_linear);
            },
            .srgb => {
                const srgb = linearToSrgb(oklabToLinearSrgb(oklchToOklab(channels)));
                return Color.init(srgb[0], srgb[1], srgb[2], color.channels[3], .srgb);
            },
            .hsl => {
                const hsl = srgbToHsl(linearToSrgb(oklabToLinearSrgb(oklchToOklab(channels))));
                return Color.init(hsl[0], hsl[1], hsl[2], color.channels[3], .hsl);
            },
            .prophoto_rgb => {
                const prophoto = linearToProphoto(oklabToLinearProphotoDirect(oklchToOklab(channels)));
                return Color.init(prophoto[0], prophoto[1], prophoto[2], color.channels[3], .prophoto_rgb);
            },
            .a98_rgb => {
                const a98 = linearToA98(oklabToLinearA98Direct(oklchToOklab(channels)));
                return Color.init(a98[0], a98[1], a98[2], color.channels[3], .a98_rgb);
            },
            else => {},
        },
        else => {},
    }

    // Shortcut: if both source and target are D50-native, route through XYZ-D50
    const result = if (color.space == .xyz_d50 and target == .srgb_linear) blk: {
        break :blk xyzD50ToLinearSrgbDirect(channels);
    } else if (color.space == .xyz_d65 and target == .display_p3_linear) blk: {
        break :blk xyzD65ToLinearDisplayP3Direct(channels);
    } else if (usesD50(target)) blk: {
        const xyz_d50 = toXyzD50(channels, color.space);
        break :blk fromXyzD50(xyz_d50, target);
    } else blk: {
        const xyz = toXyzD65(channels, color.space);
        break :blk fromXyzD65(xyz, target);
    };

    return Color{
        .channels = .{ result[0], result[1], result[2], color.channels[3] },
        .space = target,
    };
}

/// Check if a color is within the gamut of its color space.
/// Colors in unbounded spaces (Lab, LCH, OKLab, OKLCH, XYZ) are always considered in gamut.
pub fn isInGamut(color: Color) bool {
    return isInGamutWithTolerance(color, 0.0);
}

fn isInGamutWithTolerance(color: Color, tol: f64) bool {
    const bounds = color.space.gamutBounds() orelse return true;

    for (0..3) |i| {
        if (color.channels[i] < bounds[i][0] - tol or
            color.channels[i] > bounds[i][1] + tol)
        {
            return false;
        }
    }
    return true;
}

/// Map an out-of-gamut color to the gamut boundary of its current space.
/// Uses the CSS Color Level 4 gamut mapping algorithm (binary search in OKLCH).
pub fn toGamut(color: Color) Color {
    if (isInGamut(color)) return color;

    const target_space = color.space;
    const oklch = convert(color, .oklch);
    var lightness = oklch.channels[0];
    const hue = oklch.channels[2];
    const alpha = oklch.channels[3];

    const lightness_tolerance: f64 = 1e-9;
    if (lightness >= 1.0 - lightness_tolerance) {
        return convert(Color.init(1.0, 1.0, 1.0, alpha, .srgb), target_space);
    }
    if (lightness <= lightness_tolerance) {
        return convert(Color.init(0.0, 0.0, 0.0, alpha, .srgb), target_space);
    }
    lightness = math.clamp(lightness, 0.0, 1.0);

    var clipped = clipToGamut(color);
    const delta_e_threshold: f64 = 0.02;
    if (deltaEOK(clipped, color) < delta_e_threshold) return clipped;

    var min: f64 = 0.0;
    var max: f64 = oklch.channels[1];
    var min_in_gamut = true;
    const epsilon: f64 = 0.0001;

    while (max - min > epsilon) {
        const chroma = (min + max) / 2.0;
        const current = convert(Color.init(lightness, chroma, hue, alpha, .oklch), target_space);

        if (min_in_gamut and isInGamut(current)) {
            min = chroma;
            continue;
        }

        clipped = clipToGamut(current);
        const delta_e = deltaEOK(clipped, current);
        if (delta_e < delta_e_threshold) {
            if (delta_e_threshold - delta_e < epsilon) return clipped;
            min_in_gamut = false;
            min = chroma;
        } else {
            max = chroma;
        }
    }

    return clipped;
}

/// Clip each channel to the gamut bounds (simple clamping).
pub fn clipToGamut(color: Color) Color {
    const bounds = color.space.gamutBounds() orelse return color;

    var result = color;
    for (0..3) |i| {
        result.channels[i] = math.clamp(result.channels[i], bounds[i][0], bounds[i][1]);
    }
    return result;
}

/// Delta E (OK) - Euclidean distance in OKLab space.
fn deltaEOK(c1: Color, c2: Color) f64 {
    const lab1_color = convert(c1, .oklab);
    const lab2_color = convert(c2, .oklab);

    const dl = lab1_color.channels[0] - lab2_color.channels[0];
    const da = lab1_color.channels[1] - lab2_color.channels[1];
    const db = lab1_color.channels[2] - lab2_color.channels[2];

    return @sqrt(dl * dl + da * da + db * db);
}

/// Mix two colors in a given color space.
/// Weight is 0-1 where 0 = 100% c1, 1 = 100% c2.
/// For polar color spaces (HSL, LCH, OKLCH), hue is interpolated
/// along the shorter arc.
fn mix(c1: Color, c2: Color, weight: f64, space: ColorSpace) Color {
    const a = convert(c1, space);
    const b = convert(c2, space);

    const w = math.clamp(weight, 0.0, 1.0);

    var result: [4]f64 = undefined;

    for (0..3) |i| {
        if (space.isPolar() and i == 0) {
            // Hue channel - interpolate along shorter arc
            result[i] = interpolateHue(a.channels[i], b.channels[i], w);
        } else {
            result[i] = a.channels[i] * (1.0 - w) + b.channels[i] * w;
        }
    }

    // Interpolate alpha
    result[3] = a.channels[3] * (1.0 - w) + b.channels[3] * w;

    return Color{
        .channels = result,
        .space = space,
    };
}

/// Interpolate two hue values along the shorter arc.
fn interpolateHue(h1: f64, h2: f64, t: f64) f64 {
    var diff = h2 - h1;

    // Normalize difference to [-180, 180]
    if (diff > 180.0) {
        diff -= 360.0;
    } else if (diff < -180.0) {
        diff += 360.0;
    }

    var result = h1 + diff * t;
    // Normalize to [0, 360)
    result = @mod(result, 360.0);
    if (result < 0.0) result += 360.0;
    return result;
}

// ============================================================================
// Functions merged from color_helpers.zig
// ============================================================================

const NamedColorMapEntry = struct { []const u8, ColorValue };

const named_color_entries = [_]NamedColorMapEntry{
    .{ "aliceblue", .{ .r = 240, .g = 248, .b = 255, .a = 1 } },
    .{ "antiquewhite", .{ .r = 250, .g = 235, .b = 215, .a = 1 } },
    .{ "aqua", .{ .r = 0, .g = 255, .b = 255, .a = 1 } },
    .{ "aquamarine", .{ .r = 127, .g = 255, .b = 212, .a = 1 } },
    .{ "azure", .{ .r = 240, .g = 255, .b = 255, .a = 1 } },
    .{ "beige", .{ .r = 245, .g = 245, .b = 220, .a = 1 } },
    .{ "bisque", .{ .r = 255, .g = 228, .b = 196, .a = 1 } },
    .{ "black", .{ .r = 0, .g = 0, .b = 0, .a = 1 } },
    .{ "blanchedalmond", .{ .r = 255, .g = 235, .b = 205, .a = 1 } },
    .{ "blue", .{ .r = 0, .g = 0, .b = 255, .a = 1 } },
    .{ "blueviolet", .{ .r = 138, .g = 43, .b = 226, .a = 1 } },
    .{ "brown", .{ .r = 165, .g = 42, .b = 42, .a = 1 } },
    .{ "burlywood", .{ .r = 222, .g = 184, .b = 135, .a = 1 } },
    .{ "cadetblue", .{ .r = 95, .g = 158, .b = 160, .a = 1 } },
    .{ "chartreuse", .{ .r = 127, .g = 255, .b = 0, .a = 1 } },
    .{ "chocolate", .{ .r = 210, .g = 105, .b = 30, .a = 1 } },
    .{ "coral", .{ .r = 255, .g = 127, .b = 80, .a = 1 } },
    .{ "cornflowerblue", .{ .r = 100, .g = 149, .b = 237, .a = 1 } },
    .{ "cornsilk", .{ .r = 255, .g = 248, .b = 220, .a = 1 } },
    .{ "crimson", .{ .r = 220, .g = 20, .b = 60, .a = 1 } },
    .{ "cyan", .{ .r = 0, .g = 255, .b = 255, .a = 1 } },
    .{ "darkblue", .{ .r = 0, .g = 0, .b = 139, .a = 1 } },
    .{ "darkcyan", .{ .r = 0, .g = 139, .b = 139, .a = 1 } },
    .{ "darkgoldenrod", .{ .r = 184, .g = 134, .b = 11, .a = 1 } },
    .{ "darkgray", .{ .r = 169, .g = 169, .b = 169, .a = 1 } },
    .{ "darkgreen", .{ .r = 0, .g = 100, .b = 0, .a = 1 } },
    .{ "darkgrey", .{ .r = 169, .g = 169, .b = 169, .a = 1 } },
    .{ "darkkhaki", .{ .r = 189, .g = 183, .b = 107, .a = 1 } },
    .{ "darkmagenta", .{ .r = 139, .g = 0, .b = 139, .a = 1 } },
    .{ "darkolivegreen", .{ .r = 85, .g = 107, .b = 47, .a = 1 } },
    .{ "darkorange", .{ .r = 255, .g = 140, .b = 0, .a = 1 } },
    .{ "darkorchid", .{ .r = 153, .g = 50, .b = 204, .a = 1 } },
    .{ "darkred", .{ .r = 139, .g = 0, .b = 0, .a = 1 } },
    .{ "darksalmon", .{ .r = 233, .g = 150, .b = 122, .a = 1 } },
    .{ "darkseagreen", .{ .r = 143, .g = 188, .b = 143, .a = 1 } },
    .{ "darkslateblue", .{ .r = 72, .g = 61, .b = 139, .a = 1 } },
    .{ "darkslategray", .{ .r = 47, .g = 79, .b = 79, .a = 1 } },
    .{ "darkslategrey", .{ .r = 47, .g = 79, .b = 79, .a = 1 } },
    .{ "darkturquoise", .{ .r = 0, .g = 206, .b = 209, .a = 1 } },
    .{ "darkviolet", .{ .r = 148, .g = 0, .b = 211, .a = 1 } },
    .{ "deeppink", .{ .r = 255, .g = 20, .b = 147, .a = 1 } },
    .{ "deepskyblue", .{ .r = 0, .g = 191, .b = 255, .a = 1 } },
    .{ "dimgray", .{ .r = 105, .g = 105, .b = 105, .a = 1 } },
    .{ "dimgrey", .{ .r = 105, .g = 105, .b = 105, .a = 1 } },
    .{ "dodgerblue", .{ .r = 30, .g = 144, .b = 255, .a = 1 } },
    .{ "firebrick", .{ .r = 178, .g = 34, .b = 34, .a = 1 } },
    .{ "floralwhite", .{ .r = 255, .g = 250, .b = 240, .a = 1 } },
    .{ "forestgreen", .{ .r = 34, .g = 139, .b = 34, .a = 1 } },
    .{ "fuchsia", .{ .r = 255, .g = 0, .b = 255, .a = 1 } },
    .{ "gainsboro", .{ .r = 220, .g = 220, .b = 220, .a = 1 } },
    .{ "ghostwhite", .{ .r = 248, .g = 248, .b = 255, .a = 1 } },
    .{ "gold", .{ .r = 255, .g = 215, .b = 0, .a = 1 } },
    .{ "goldenrod", .{ .r = 218, .g = 165, .b = 32, .a = 1 } },
    .{ "gray", .{ .r = 128, .g = 128, .b = 128, .a = 1 } },
    .{ "green", .{ .r = 0, .g = 128, .b = 0, .a = 1 } },
    .{ "greenyellow", .{ .r = 173, .g = 255, .b = 47, .a = 1 } },
    .{ "grey", .{ .r = 128, .g = 128, .b = 128, .a = 1 } },
    .{ "honeydew", .{ .r = 240, .g = 255, .b = 240, .a = 1 } },
    .{ "hotpink", .{ .r = 255, .g = 105, .b = 180, .a = 1 } },
    .{ "indianred", .{ .r = 205, .g = 92, .b = 92, .a = 1 } },
    .{ "indigo", .{ .r = 75, .g = 0, .b = 130, .a = 1 } },
    .{ "ivory", .{ .r = 255, .g = 255, .b = 240, .a = 1 } },
    .{ "khaki", .{ .r = 240, .g = 230, .b = 140, .a = 1 } },
    .{ "lavender", .{ .r = 230, .g = 230, .b = 250, .a = 1 } },
    .{ "lavenderblush", .{ .r = 255, .g = 240, .b = 245, .a = 1 } },
    .{ "lawngreen", .{ .r = 124, .g = 252, .b = 0, .a = 1 } },
    .{ "lemonchiffon", .{ .r = 255, .g = 250, .b = 205, .a = 1 } },
    .{ "lightblue", .{ .r = 173, .g = 216, .b = 230, .a = 1 } },
    .{ "lightcoral", .{ .r = 240, .g = 128, .b = 128, .a = 1 } },
    .{ "lightcyan", .{ .r = 224, .g = 255, .b = 255, .a = 1 } },
    .{ "lightgoldenrodyellow", .{ .r = 250, .g = 250, .b = 210, .a = 1 } },
    .{ "lightgray", .{ .r = 211, .g = 211, .b = 211, .a = 1 } },
    .{ "lightgreen", .{ .r = 144, .g = 238, .b = 144, .a = 1 } },
    .{ "lightgrey", .{ .r = 211, .g = 211, .b = 211, .a = 1 } },
    .{ "lightpink", .{ .r = 255, .g = 182, .b = 193, .a = 1 } },
    .{ "lightsalmon", .{ .r = 255, .g = 160, .b = 122, .a = 1 } },
    .{ "lightseagreen", .{ .r = 32, .g = 178, .b = 170, .a = 1 } },
    .{ "lightskyblue", .{ .r = 135, .g = 206, .b = 250, .a = 1 } },
    .{ "lightslategray", .{ .r = 119, .g = 136, .b = 153, .a = 1 } },
    .{ "lightslategrey", .{ .r = 119, .g = 136, .b = 153, .a = 1 } },
    .{ "lightsteelblue", .{ .r = 176, .g = 196, .b = 222, .a = 1 } },
    .{ "lightyellow", .{ .r = 255, .g = 255, .b = 224, .a = 1 } },
    .{ "lime", .{ .r = 0, .g = 255, .b = 0, .a = 1 } },
    .{ "limegreen", .{ .r = 50, .g = 205, .b = 50, .a = 1 } },
    .{ "linen", .{ .r = 250, .g = 240, .b = 230, .a = 1 } },
    .{ "magenta", .{ .r = 255, .g = 0, .b = 255, .a = 1 } },
    .{ "maroon", .{ .r = 128, .g = 0, .b = 0, .a = 1 } },
    .{ "mediumaquamarine", .{ .r = 102, .g = 205, .b = 170, .a = 1 } },
    .{ "mediumblue", .{ .r = 0, .g = 0, .b = 205, .a = 1 } },
    .{ "mediumorchid", .{ .r = 186, .g = 85, .b = 211, .a = 1 } },
    .{ "mediumpurple", .{ .r = 147, .g = 112, .b = 219, .a = 1 } },
    .{ "mediumseagreen", .{ .r = 60, .g = 179, .b = 113, .a = 1 } },
    .{ "mediumslateblue", .{ .r = 123, .g = 104, .b = 238, .a = 1 } },
    .{ "mediumspringgreen", .{ .r = 0, .g = 250, .b = 154, .a = 1 } },
    .{ "mediumturquoise", .{ .r = 72, .g = 209, .b = 204, .a = 1 } },
    .{ "mediumvioletred", .{ .r = 199, .g = 21, .b = 133, .a = 1 } },
    .{ "midnightblue", .{ .r = 25, .g = 25, .b = 112, .a = 1 } },
    .{ "mintcream", .{ .r = 245, .g = 255, .b = 250, .a = 1 } },
    .{ "mistyrose", .{ .r = 255, .g = 228, .b = 225, .a = 1 } },
    .{ "moccasin", .{ .r = 255, .g = 228, .b = 181, .a = 1 } },
    .{ "navajowhite", .{ .r = 255, .g = 222, .b = 173, .a = 1 } },
    .{ "navy", .{ .r = 0, .g = 0, .b = 128, .a = 1 } },
    .{ "oldlace", .{ .r = 253, .g = 245, .b = 230, .a = 1 } },
    .{ "olive", .{ .r = 128, .g = 128, .b = 0, .a = 1 } },
    .{ "olivedrab", .{ .r = 107, .g = 142, .b = 35, .a = 1 } },
    .{ "orange", .{ .r = 255, .g = 165, .b = 0, .a = 1 } },
    .{ "orangered", .{ .r = 255, .g = 69, .b = 0, .a = 1 } },
    .{ "orchid", .{ .r = 218, .g = 112, .b = 214, .a = 1 } },
    .{ "palegoldenrod", .{ .r = 238, .g = 232, .b = 170, .a = 1 } },
    .{ "palegreen", .{ .r = 152, .g = 251, .b = 152, .a = 1 } },
    .{ "paleturquoise", .{ .r = 175, .g = 238, .b = 238, .a = 1 } },
    .{ "palevioletred", .{ .r = 219, .g = 112, .b = 147, .a = 1 } },
    .{ "papayawhip", .{ .r = 255, .g = 239, .b = 213, .a = 1 } },
    .{ "peachpuff", .{ .r = 255, .g = 218, .b = 185, .a = 1 } },
    .{ "peru", .{ .r = 205, .g = 133, .b = 63, .a = 1 } },
    .{ "pink", .{ .r = 255, .g = 192, .b = 203, .a = 1 } },
    .{ "plum", .{ .r = 221, .g = 160, .b = 221, .a = 1 } },
    .{ "powderblue", .{ .r = 176, .g = 224, .b = 230, .a = 1 } },
    .{ "purple", .{ .r = 128, .g = 0, .b = 128, .a = 1 } },
    .{ "rebeccapurple", .{ .r = 102, .g = 51, .b = 153, .a = 1 } },
    .{ "red", .{ .r = 255, .g = 0, .b = 0, .a = 1 } },
    .{ "rosybrown", .{ .r = 188, .g = 143, .b = 143, .a = 1 } },
    .{ "royalblue", .{ .r = 65, .g = 105, .b = 225, .a = 1 } },
    .{ "saddlebrown", .{ .r = 139, .g = 69, .b = 19, .a = 1 } },
    .{ "salmon", .{ .r = 250, .g = 128, .b = 114, .a = 1 } },
    .{ "sandybrown", .{ .r = 244, .g = 164, .b = 96, .a = 1 } },
    .{ "seagreen", .{ .r = 46, .g = 139, .b = 87, .a = 1 } },
    .{ "seashell", .{ .r = 255, .g = 245, .b = 238, .a = 1 } },
    .{ "sienna", .{ .r = 160, .g = 82, .b = 45, .a = 1 } },
    .{ "silver", .{ .r = 192, .g = 192, .b = 192, .a = 1 } },
    .{ "skyblue", .{ .r = 135, .g = 206, .b = 235, .a = 1 } },
    .{ "slateblue", .{ .r = 106, .g = 90, .b = 205, .a = 1 } },
    .{ "slategray", .{ .r = 112, .g = 128, .b = 144, .a = 1 } },
    .{ "slategrey", .{ .r = 112, .g = 128, .b = 144, .a = 1 } },
    .{ "snow", .{ .r = 255, .g = 250, .b = 250, .a = 1 } },
    .{ "springgreen", .{ .r = 0, .g = 255, .b = 127, .a = 1 } },
    .{ "steelblue", .{ .r = 70, .g = 130, .b = 180, .a = 1 } },
    .{ "tan", .{ .r = 210, .g = 180, .b = 140, .a = 1 } },
    .{ "teal", .{ .r = 0, .g = 128, .b = 128, .a = 1 } },
    .{ "thistle", .{ .r = 216, .g = 191, .b = 216, .a = 1 } },
    .{ "tomato", .{ .r = 255, .g = 99, .b = 71, .a = 1 } },
    .{ "transparent", .{ .r = 0, .g = 0, .b = 0, .a = 0 } },
    .{ "turquoise", .{ .r = 64, .g = 224, .b = 208, .a = 1 } },
    .{ "violet", .{ .r = 238, .g = 130, .b = 238, .a = 1 } },
    .{ "wheat", .{ .r = 245, .g = 222, .b = 179, .a = 1 } },
    .{ "white", .{ .r = 255, .g = 255, .b = 255, .a = 1 } },
    .{ "whitesmoke", .{ .r = 245, .g = 245, .b = 245, .a = 1 } },
    .{ "yellow", .{ .r = 255, .g = 255, .b = 0, .a = 1 } },
    .{ "yellowgreen", .{ .r = 154, .g = 205, .b = 50, .a = 1 } },
};

const named_color_map = std.StaticStringMap(ColorValue).initComptime(named_color_entries);

pub fn namedColorForRgb(r: u8, g: u8, b: u8) ?[]const u8 {
    for (named_color_entries) |entry| {
        const color = entry[1];
        if (color.a != 1.0) continue;
        if (color.r == @as(f64, @floatFromInt(r)) and
            color.g == @as(f64, @floatFromInt(g)) and
            color.b == @as(f64, @floatFromInt(b)))
        {
            return entry[0];
        }
    }
    return null;
}

pub fn lookupNamedColor(name: []const u8) ?ColorValue {
    // Case-insensitive lookup: convert name to lowercase first
    var lower_buf: [64]u8 = undefined;
    if (name.len > lower_buf.len) return null;
    for (name, 0..) |c, idx| {
        lower_buf[idx] = std.ascii.toLower(c);
    }
    const lower_name = lower_buf[0..name.len];
    if (named_color_map.get(lower_name)) |color| {
        var result = color;
        result.repr = if (std.ascii.eqlIgnoreCase(name, "transparent")) .literal_transparent else .literal_named;
        return result;
    }
    return null;
}

pub fn hueToRgb(p: f64, q: f64, t_in: f64) f64 {
    var t = t_in;
    if (t < 0) t += 1;
    if (t > 1) t -= 1;
    if (t < 1.0 / 6.0) return p + (q - p) * 6 * t;
    if (t < 1.0 / 2.0) return q;
    if (t < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - t) * 6;
    return p;
}

pub fn convertAngleToDeg(value: f64, unit: ?[]const u8) f64 {
    if (unit) |u| {
        if (std.mem.eql(u8, u, "rad")) return value * 180.0 / std.math.pi;
        if (std.mem.eql(u8, u, "grad")) return value * 0.9;
        if (std.mem.eql(u8, u, "turn")) return value * 360.0;
    }
    return value;
}

pub fn scaleValueInRange(current: f64, min: f64, max: f64, factor: f64) f64 {
    if (factor >= 0) {
        if (current >= max) return current;
        return current + (max - current) * factor;
    } else {
        if (current <= min) return current;
        return current + (current - min) * factor;
    }
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const expectApproxEqAbs = testing.expectApproxEqAbs;

const tolerance: f64 = 0.001;

fn expectColorApprox(actual: Color, expected: Color) !void {
    try testing.expectEqual(actual.space, expected.space);
    for (0..4) |i| {
        try expectApproxEqAbs(expected.channels[i], actual.channels[i], tolerance);
    }
}

// --- sRGB <-> HSL round-trip ---

test "sRGB to HSL: pure red" {
    const red = Color.init(1.0, 0.0, 0.0, 1.0, .srgb);
    const hsl = convert(red, .hsl);
    try expectApproxEqAbs(@as(f64, 0.0), hsl.channels[0], tolerance);
    try expectApproxEqAbs(@as(f64, 100.0), hsl.channels[1], tolerance);
    try expectApproxEqAbs(@as(f64, 50.0), hsl.channels[2], tolerance);
    try expectApproxEqAbs(@as(f64, 1.0), hsl.channels[3], tolerance);
}

test "sRGB to HSL: pure green" {
    const green = Color.init(0.0, 1.0, 0.0, 1.0, .srgb);
    const hsl = convert(green, .hsl);
    try expectApproxEqAbs(@as(f64, 120.0), hsl.channels[0], tolerance);
    try expectApproxEqAbs(@as(f64, 100.0), hsl.channels[1], tolerance);
    try expectApproxEqAbs(@as(f64, 50.0), hsl.channels[2], tolerance);
}

test "sRGB to HSL: pure blue" {
    const blue = Color.init(0.0, 0.0, 1.0, 1.0, .srgb);
    const hsl = convert(blue, .hsl);
    try expectApproxEqAbs(@as(f64, 240.0), hsl.channels[0], tolerance);
    try expectApproxEqAbs(@as(f64, 100.0), hsl.channels[1], tolerance);
    try expectApproxEqAbs(@as(f64, 50.0), hsl.channels[2], tolerance);
}

test "HSL to sRGB round-trip" {
    const original = Color.init(210.0, 80.0, 60.0, 0.9, .hsl);
    const srgb = convert(original, .srgb);
    const back = convert(srgb, .hsl);
    try expectColorApprox(back, original);
}

test "sRGB to HSL round-trip for arbitrary color" {
    const original = Color.init(0.4, 0.6, 0.8, 1.0, .srgb);
    const hsl = convert(original, .hsl);
    const back = convert(hsl, .srgb);
    try expectColorApprox(back, original);
}

// --- sRGB <-> Lab round-trip ---

test "sRGB to Lab: white" {
    const white = Color.init(1.0, 1.0, 1.0, 1.0, .srgb);
    const lab = convert(white, .lab);
    // Small deviation due to Bradford D65->D50 chromatic adaptation
    const lab_white_tol: f64 = 0.1;
    try expectApproxEqAbs(@as(f64, 100.0), lab.channels[0], lab_white_tol);
    try expectApproxEqAbs(@as(f64, 0.0), lab.channels[1], lab_white_tol);
    try expectApproxEqAbs(@as(f64, 0.0), lab.channels[2], lab_white_tol);
}

test "sRGB to Lab: black" {
    const black = Color.init(0.0, 0.0, 0.0, 1.0, .srgb);
    const lab = convert(black, .lab);
    try expectApproxEqAbs(@as(f64, 0.0), lab.channels[0], tolerance);
    try expectApproxEqAbs(@as(f64, 0.0), lab.channels[1], tolerance);
    try expectApproxEqAbs(@as(f64, 0.0), lab.channels[2], tolerance);
}

test "sRGB to Lab round-trip" {
    const original = Color.init(0.5, 0.3, 0.7, 1.0, .srgb);
    const lab = convert(original, .lab);
    const back = convert(lab, .srgb);
    try expectColorApprox(back, original);
}

test "sRGB to Lab round-trip: another color" {
    const original = Color.init(0.8, 0.2, 0.4, 0.75, .srgb);
    const lab = convert(original, .lab);
    const back = convert(lab, .srgb);
    try expectColorApprox(back, original);
}

// --- OKLab / OKLCH conversions ---

test "sRGB to OKLab: white" {
    const white = Color.init(1.0, 1.0, 1.0, 1.0, .srgb);
    const oklab = convert(white, .oklab);
    try expectApproxEqAbs(@as(f64, 1.0), oklab.channels[0], tolerance);
    try expectApproxEqAbs(@as(f64, 0.0), oklab.channels[1], tolerance);
    try expectApproxEqAbs(@as(f64, 0.0), oklab.channels[2], tolerance);
}

test "sRGB to OKLab: black" {
    const black = Color.init(0.0, 0.0, 0.0, 1.0, .srgb);
    const oklab = convert(black, .oklab);
    try expectApproxEqAbs(@as(f64, 0.0), oklab.channels[0], tolerance);
    try expectApproxEqAbs(@as(f64, 0.0), oklab.channels[1], tolerance);
    try expectApproxEqAbs(@as(f64, 0.0), oklab.channels[2], tolerance);
}

test "sRGB to OKLab round-trip" {
    const original = Color.init(0.3, 0.6, 0.9, 1.0, .srgb);
    const oklab = convert(original, .oklab);
    const back = convert(oklab, .srgb);
    try expectColorApprox(back, original);
}

test "A98 extreme out-of-range to XYZ preserves Sass precision" {
    const converted = convert(Color.init(-999999.0, 0.0, 0.0, 1.0, .a98_rgb), .xyz_d65);
    try expectApproxEqAbs(@as(f64, -9041452038524.758), converted.channels[0], 0.001);
    try expectApproxEqAbs(@as(f64, -4661998707364.328), converted.channels[1], 0.001);
    try expectApproxEqAbs(@as(f64, -423818064305.84784), converted.channels[2], 0.001);
}

test "sRGB to OKLCH round-trip" {
    const original = Color.init(0.7, 0.2, 0.5, 1.0, .srgb);
    const oklch = convert(original, .oklch);
    const back = convert(oklch, .srgb);
    try expectColorApprox(back, original);
}

test "OKLab to OKLCH and back" {
    const oklab = Color.init(0.5, 0.1, -0.05, 1.0, .oklab);
    const oklch = convert(oklab, .oklch);
    const back = convert(oklch, .oklab);
    try expectColorApprox(back, oklab);
}

// --- LCH conversions ---

test "Lab to LCH round-trip" {
    const lab = Color.init(50.0, 30.0, -40.0, 1.0, .lab);
    const lch = convert(lab, .lch);
    const back = convert(lch, .lab);
    // With D50 shortcut, Lab<->LCH avoids D50<->D65 round-trip
    try expectColorApprox(back, lab);
}

test "sRGB to LCH round-trip" {
    const original = Color.init(0.6, 0.4, 0.8, 1.0, .srgb);
    const lch = convert(original, .lch);
    const back = convert(lch, .srgb);
    try expectColorApprox(back, original);
}

// --- HWB conversions ---

test "HWB to sRGB: pure red" {
    const red = Color.init(0.0, 0.0, 0.0, 1.0, .hwb);
    const srgb = convert(red, .srgb);
    try expectApproxEqAbs(@as(f64, 1.0), srgb.channels[0], tolerance);
    try expectApproxEqAbs(@as(f64, 0.0), srgb.channels[1], tolerance);
    try expectApproxEqAbs(@as(f64, 0.0), srgb.channels[2], tolerance);
}

test "HWB to sRGB round-trip" {
    const original = Color.init(180.0, 20.0, 30.0, 1.0, .hwb);
    const srgb = convert(original, .srgb);
    const back = convert(srgb, .hwb);
    try expectColorApprox(back, original);
}

// --- Display-P3 conversions ---

test "sRGB to Display-P3 round-trip" {
    const original = Color.init(0.5, 0.5, 0.5, 1.0, .srgb);
    const p3 = convert(original, .display_p3);
    const back = convert(p3, .srgb);
    try expectColorApprox(back, original);
}

test "Display-P3 to sRGB round-trip" {
    const original = Color.init(0.6, 0.4, 0.8, 1.0, .display_p3);
    const srgb = convert(original, .srgb);
    const back = convert(srgb, .display_p3);
    try expectColorApprox(back, original);
}

// --- A98-RGB conversions ---

test "sRGB to A98-RGB round-trip" {
    const original = Color.init(0.3, 0.5, 0.7, 1.0, .srgb);
    const a98 = convert(original, .a98_rgb);
    const back = convert(a98, .srgb);
    try expectColorApprox(back, original);
}

// --- ProPhoto-RGB conversions ---

test "sRGB to ProPhoto-RGB round-trip" {
    const original = Color.init(0.4, 0.6, 0.2, 1.0, .srgb);
    const prophoto = convert(original, .prophoto_rgb);
    const back = convert(prophoto, .srgb);
    try expectColorApprox(back, original);
}

// --- Rec2020 conversions ---

test "sRGB to Rec2020 round-trip" {
    const original = Color.init(0.8, 0.1, 0.5, 1.0, .srgb);
    const rec = convert(original, .rec2020);
    const back = convert(rec, .srgb);
    try expectColorApprox(back, original);
}

// --- XYZ conversions ---

test "sRGB to XYZ-D65 round-trip" {
    const original = Color.init(0.5, 0.3, 0.8, 1.0, .srgb);
    const xyz = convert(original, .xyz_d65);
    const back = convert(xyz, .srgb);
    try expectColorApprox(back, original);
}

test "sRGB to XYZ-D50 round-trip" {
    const original = Color.init(0.5, 0.3, 0.8, 1.0, .srgb);
    const xyz = convert(original, .xyz_d50);
    const back = convert(xyz, .srgb);
    try expectColorApprox(back, original);
}

test "XYZ-D50 to XYZ-D65 round-trip" {
    const original = Color.init(0.4, 0.5, 0.3, 1.0, .xyz_d50);
    const d65 = convert(original, .xyz_d65);
    const back = convert(d65, .xyz_d50);
    try expectColorApprox(back, original);
}

// --- Gamut checking ---

test "isInGamut: valid sRGB" {
    const c = Color.init(0.5, 0.5, 0.5, 1.0, .srgb);
    try testing.expect(isInGamut(c));
}

test "isInGamut: out of gamut sRGB" {
    const c = Color.init(1.2, 0.5, 0.5, 1.0, .srgb);
    try testing.expect(!isInGamut(c));
}

test "isInGamut: negative sRGB" {
    const c = Color.init(-0.1, 0.5, 0.5, 1.0, .srgb);
    try testing.expect(!isInGamut(c));
}

test "isInGamut: Lab is always in gamut" {
    const c = Color.init(50.0, 200.0, -200.0, 1.0, .lab);
    try testing.expect(isInGamut(c));
}

test "isInGamut: XYZ is always in gamut" {
    const c = Color.init(2.0, 1.0, 3.0, 1.0, .xyz_d65);
    try testing.expect(isInGamut(c));
}

// --- Gamut mapping ---

test "toGamut: already in gamut" {
    const c = Color.init(0.5, 0.5, 0.5, 1.0, .srgb);
    const mapped = toGamut(c);
    try expectColorApprox(mapped, c);
}

test "toGamut: out of gamut gets mapped in" {
    const c = Color.init(1.5, -0.2, 0.5, 1.0, .srgb);
    const mapped = toGamut(c);
    try testing.expect(isInGamutWithTolerance(mapped, tolerance));
}

test "toGamut: display-p3 out of gamut" {
    // A display-P3 color that's out of sRGB gamut, convert to sRGB and map
    const p3 = Color.init(1.0, 0.0, 0.0, 1.0, .display_p3);
    const srgb = convert(p3, .srgb);
    const mapped = toGamut(srgb);
    try testing.expect(isInGamutWithTolerance(mapped, tolerance));
}

// --- Color mixing ---

test "mix: 50/50 in sRGB" {
    const black = Color.init(0.0, 0.0, 0.0, 1.0, .srgb);
    const white = Color.init(1.0, 1.0, 1.0, 1.0, .srgb);
    const mixed = mix(black, white, 0.5, .srgb);
    try expectApproxEqAbs(@as(f64, 0.5), mixed.channels[0], tolerance);
    try expectApproxEqAbs(@as(f64, 0.5), mixed.channels[1], tolerance);
    try expectApproxEqAbs(@as(f64, 0.5), mixed.channels[2], tolerance);
    try expectApproxEqAbs(@as(f64, 1.0), mixed.channels[3], tolerance);
}

test "mix: 0% weight returns first color" {
    const red = Color.init(1.0, 0.0, 0.0, 1.0, .srgb);
    const blue = Color.init(0.0, 0.0, 1.0, 1.0, .srgb);
    const mixed = mix(red, blue, 0.0, .srgb);
    try expectApproxEqAbs(@as(f64, 1.0), mixed.channels[0], tolerance);
    try expectApproxEqAbs(@as(f64, 0.0), mixed.channels[2], tolerance);
}

test "mix: 100% weight returns second color" {
    const red = Color.init(1.0, 0.0, 0.0, 1.0, .srgb);
    const blue = Color.init(0.0, 0.0, 1.0, 1.0, .srgb);
    const mixed = mix(red, blue, 1.0, .srgb);
    try expectApproxEqAbs(@as(f64, 0.0), mixed.channels[0], tolerance);
    try expectApproxEqAbs(@as(f64, 1.0), mixed.channels[2], tolerance);
}

test "mix: alpha interpolation" {
    const c1 = Color.init(1.0, 0.0, 0.0, 1.0, .srgb);
    const c2 = Color.init(0.0, 0.0, 1.0, 0.0, .srgb);
    const mixed = mix(c1, c2, 0.5, .srgb);
    try expectApproxEqAbs(@as(f64, 0.5), mixed.channels[3], tolerance);
}

test "mix: in OKLab space" {
    const red = Color.init(1.0, 0.0, 0.0, 1.0, .srgb);
    const blue = Color.init(0.0, 0.0, 1.0, 1.0, .srgb);
    const mixed = mix(red, blue, 0.5, .oklab);
    try testing.expectEqual(ColorSpace.oklab, mixed.space);
    // OKLab mixing should produce a valid result
    const back = convert(mixed, .srgb);
    // Just verify it produces reasonable values
    try testing.expect(back.channels[0] > -0.5 and back.channels[0] < 1.5);
}

test "mix: hue interpolation shorter arc" {
    // Red (hue=0) and blue (hue=240) - shorter arc goes through 300 (magenta)
    const c1 = Color.init(0.0, 100.0, 50.0, 1.0, .hsl);
    const c2 = Color.init(240.0, 100.0, 50.0, 1.0, .hsl);
    const mixed = mix(c1, c2, 0.5, .hsl);
    // Shorter arc: 0 -> 360 -> 240, midpoint at 300
    try expectApproxEqAbs(@as(f64, 300.0), mixed.channels[0], tolerance);
}

test "mix: hue interpolation same direction" {
    // 60 degrees and 180 degrees - shorter arc goes through 120
    const c1 = Color.init(60.0, 80.0, 50.0, 1.0, .hsl);
    const c2 = Color.init(180.0, 80.0, 50.0, 1.0, .hsl);
    const mixed = mix(c1, c2, 0.5, .hsl);
    try expectApproxEqAbs(@as(f64, 120.0), mixed.channels[0], tolerance);
}

// --- Cross-space round-trips ---

test "full round-trip: sRGB -> Lab -> LCH -> OKLab -> OKLCH -> sRGB" {
    const original = Color.init(0.6, 0.3, 0.8, 0.9, .srgb);
    const lab = convert(original, .lab);
    const lch = convert(lab, .lch);
    const oklab = convert(lch, .oklab);
    const oklch = convert(oklab, .oklch);
    const back = convert(oklch, .srgb);
    try expectColorApprox(back, original);
}

test "full round-trip: sRGB -> Display-P3 -> A98-RGB -> ProPhoto -> Rec2020 -> sRGB" {
    const original = Color.init(0.5, 0.4, 0.7, 1.0, .srgb);
    const p3 = convert(original, .display_p3);
    const a98 = convert(p3, .a98_rgb);
    const prophoto = convert(a98, .prophoto_rgb);
    const rec = convert(prophoto, .rec2020);
    const back = convert(rec, .srgb);
    try expectColorApprox(back, original);
}

test "full round-trip: sRGB -> XYZ-D65 -> XYZ-D50 -> Lab -> sRGB" {
    const original = Color.init(0.2, 0.8, 0.4, 1.0, .srgb);
    const xyz_d65 = convert(original, .xyz_d65);
    const xyz_d50 = convert(xyz_d65, .xyz_d50);
    const lab = convert(xyz_d50, .lab);
    const back = convert(lab, .srgb);
    try expectColorApprox(back, original);
}

test "alpha is preserved through conversions" {
    const original = Color.init(0.5, 0.5, 0.5, 0.42, .srgb);
    const lab = convert(original, .lab);
    try expectApproxEqAbs(@as(f64, 0.42), lab.channels[3], tolerance);
    const back = convert(lab, .srgb);
    try expectApproxEqAbs(@as(f64, 0.42), back.channels[3], tolerance);
}

test "convert to same space is identity" {
    const c = Color.init(0.3, 0.6, 0.9, 0.5, .srgb);
    const same = convert(c, .srgb);
    try expectColorApprox(same, c);
}

// --- sRGB gamma transfer function ---

test "sRGB gamma: linearize and gamma round-trip" {
    const values = [_]f64{ 0.0, 0.01, 0.04045, 0.1, 0.5, 0.9, 1.0 };
    for (values) |v| {
        const linear = srgbLinearize(v);
        const back = srgbGamma(linear);
        try expectApproxEqAbs(v, back, tolerance);
    }
}

test "sRGB gamma: known values" {
    // sRGB 0.5 should linearize to approximately 0.214
    const linear = srgbLinearize(0.5);
    try expectApproxEqAbs(@as(f64, 0.214), linear, 0.001);
}

// --- Polar space utilities ---

test "ColorSpace.isPolar" {
    try testing.expect(ColorSpace.hsl.isPolar());
    try testing.expect(ColorSpace.hwb.isPolar());
    try testing.expect(ColorSpace.lch.isPolar());
    try testing.expect(ColorSpace.oklch.isPolar());
    try testing.expect(!ColorSpace.srgb.isPolar());
    try testing.expect(!ColorSpace.lab.isPolar());
    try testing.expect(!ColorSpace.oklab.isPolar());
    try testing.expect(!ColorSpace.xyz_d65.isPolar());
}

// --- Edge cases ---

test "conversion of achromatic color (gray)" {
    // Gray should have near-zero chroma in LCH/OKLCH
    const gray = Color.init(0.5, 0.5, 0.5, 1.0, .srgb);
    const oklch = convert(gray, .oklch);
    try testing.expect(oklch.channels[1] < 0.01); // chroma should be ~0
}

test "conversion of very dark color" {
    const dark = Color.init(0.01, 0.01, 0.01, 1.0, .srgb);
    const lab = convert(dark, .lab);
    try testing.expect(lab.channels[0] < 5.0); // L should be very low
    const back = convert(lab, .srgb);
    try expectColorApprox(back, dark);
}

test "conversion of very bright color" {
    const bright = Color.init(0.99, 0.99, 0.99, 1.0, .srgb);
    const lab = convert(bright, .lab);
    try testing.expect(lab.channels[0] > 95.0); // L should be very high
    const back = convert(lab, .srgb);
    try expectColorApprox(back, bright);
}

test "Color.eql with tolerance" {
    const c1 = Color.init(0.5, 0.5, 0.5, 1.0, .srgb);
    const c2 = Color.init(0.5005, 0.4995, 0.5001, 1.0, .srgb);
    try testing.expect(c1.eql(c2, 0.001));
}

test "Color.eql different spaces" {
    const c1 = Color.init(0.5, 0.5, 0.5, 1.0, .srgb);
    const c2 = Color.init(0.5, 0.5, 0.5, 1.0, .display_p3);
    try testing.expect(!c1.eql(c2, 0.001));
}
