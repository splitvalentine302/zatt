class Zatt < Formula
  desc "macOS CLI to control MacBook battery charging via SMC"
  homepage "https://github.com/maximbilan/zatt"
  url "https://github.com/maximbilan/zatt/releases/download/v0.1.4/zatt-macos-arm64.tar.gz"
  sha256 "16f09756795bb91c175abf9bd6dd4455ca482e6a0dac9d4dcc956a7fc27ecc5d"
  version "0.1.4"
  license "MIT"

  depends_on arch: :arm64
  depends_on macos: :ventura

  on_arm do
    def install
      bin.install "bin/zatt"
    end
  end

  test do
    system "#{bin}/zatt", "status"
  end
end
