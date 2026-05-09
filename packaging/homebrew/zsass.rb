class Zsass < Formula
  desc "Sass compiler implemented in Zig"
  homepage "https://github.com/nihen/zsass"
  version "0.1.0"
  license "MIT"

  on_macos do
    on_arm do
      url "https://github.com/nihen/zsass/releases/download/v0.1.0/zsass-v0.1.0-macos-aarch64.tar.gz"
      sha256 "a5e8225ecb75fe5730965734a150e7427431ed783a7234313ee154f5373082de"
    end
    on_intel do
      url "https://github.com/nihen/zsass/releases/download/v0.1.0/zsass-v0.1.0-macos-x86_64.tar.gz"
      sha256 "d02aa592122430e53a93e97dbded625fd8ecfa35cdfbd0c8d2730f844a11e819"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/nihen/zsass/releases/download/v0.1.0/zsass-v0.1.0-linux-aarch64.tar.gz"
      sha256 "a2d83b71547a074d408d46c6282e30438061a7b0f7bcc4d50b219973e171457d"
    end
    on_intel do
      url "https://github.com/nihen/zsass/releases/download/v0.1.0/zsass-v0.1.0-linux-x86_64.tar.gz"
      sha256 "184e5e334f49dfe3b05a2b12278040ba1febcefbd6758005b46e321d8c5bc678"
    end
  end

  def install
    bin.install "zsass"
  end

  test do
    assert_match "zsass #{version}", shell_output("#{bin}/zsass --version").strip
  end
end
