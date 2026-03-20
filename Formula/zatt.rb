class Zatt < Formula
  desc "macOS CLI to control MacBook battery charging via SMC"
  homepage "https://github.com/maximbilan/zatt"
  url "https://github.com/maximbilan/zatt/releases/download/v1.0.5/zatt-macos-arm64.tar.gz"
  sha256 "7caa1cd062fa10d958f4eeae9f9c5121fe73d3f22dbb74fb41fd8c0854b00dc7"
  version "1.0.5"
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
