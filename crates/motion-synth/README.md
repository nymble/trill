# motion-synth

`no_std`, allocation-free motion-to-music engine: IMU motion processing (gyro calibration, complementary filter, taps), gesture → parameter mapping (optional Trill touch), and a block-based audio-rate voice. Also defines the control mailbox and the framed PCM stream used by the XIAO Sense firmware.

Design, latency budget and output paths: [docs/motion-synth.md](../../docs/motion-synth.md).

```sh
cargo test -p motion-synth
cargo run -p motion-synth --example render_wav -- demo.wav [16000|32000|48000] [block]
```
