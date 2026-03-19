class Zatt < Formula
  desc "macOS CLI to control MacBook battery charging via SMC"
  homepage "https://github.com/maximbilan/zatt"
  url "https://github.com/maximbilan/zatt/releases/download/v0.1.1/zatt-macos-arm64.tar.gz"
  sha256 "59f8dd1b659e9136f10f6b36a420bdc85354e73a9964a1122a4dac3d533e2e6f"
  version "0.1.1"
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
