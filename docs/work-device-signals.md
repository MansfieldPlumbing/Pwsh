# Work order: on-device Morse and V.21

Planned 2026-10-01. ROADMAP.md owns checkbox status. This optional port preserves the APK preview finish line. Android capability claims require the hardware that supplies that capability; emulator/arm32 devices without a flash or light sensor must return an explicit unsupported result rather than fabricate a pass.

## Architecture

- Codec: PowerShell-authored conversion, pulse/byte framing and reference algorithms. Lower repeated DSP and sensor decoding into persisted managed IL using the existing emitter; no per-sample SMA dispatch.
- Platform: owned JNI CameraManager torch calls, NDK sensor event queue and AAudio input/output. Admit exact headers/source and method signatures. Replace Xamarin types and browser/remoting glue.
- Sessions: blocking worker waits or event wakeups, monotonic deadlines, cancellation, bounded queues/buffers, structured progress/results and explicit cleanup. Torch timing uses scheduled absolute deadlines, not a periodic poll. Stop/close returns hardware to its declared idle state or reports cleanup failure.
- UI: console commands first. A retained pane may show text, status, decoded messages and levels using the same session events. No console grid or graphical pane is required by the codec.

Proposed command names: Set-Flashlight, ConvertTo-Morse, ConvertFrom-Morse, Send-Morse, Receive-Morse, ConvertTo-V21, ConvertFrom-V21, Send-V21 and Receive-V21. Freeze parameter/output semantics before implementation; conversion emits data rather than performing device I/O. No command uses ADB on the device.

## M0: admit reference and specifications

Fetch pushed Subsystem sources at full revision 2c8dd80454a46db0174fe5d6cf5cec4e64e1d9fb from upstream, with SHA-256 identities and MIT notices. Scratch acquisition has verified the codec, actuator/light and cmdlet blobs; lib admission remains open. Pin applicable Morse timing/alphabet and ITU V.21 specifications plus platform headers/implementations. Donor code is a reference/oracle, not a product assembly. Record declared formats separately from standards claims.

Exit: admitted source/specification identities, supported formats/rates/limits and named lowering targets/measurements. No generated native logic without the repository's N gates.

## M1: direct flashlight capability

Bind camera enumeration, characteristics and setTorchMode through JNI. Choose a flash-equipped camera, handle resource contention/unavailability and trace permission requirements against the actual target/pinned implementation. Do not request unrelated permissions. Separate desired and observed state; use a scoped fixed callback only where required, without a general Java subclassing framework.

Exit: console commands turn a real test-device torch ON/OFF without ADB execution; failure/unsupported/cancel/lifecycle behavior is explicit. Record library/JNI/resource cleanup and visible hardware evidence.

## M2: Morse codec and transmit

Port the table, conversion and pulse model into PowerShell. Define unsupported-character handling, word boundaries and units. Correct donor nine-unit word gaps to seven; separate calibration/end markers from ordinary Morse timing. Validate duration and message bounds. Emit a reusable pulse sequence before scheduling torch transitions; timed waits occur away from the main looper and cancellation attempts OFF.

Exit: independent timing/alphabet vectors and emitted/reference comparison, measured physical pulse timing at a supported speed, cancellation and error cleanup. Never infer optical timing from command dispatch time alone.

## M3: light receive

Use ASensorManager/ASensorEventQueue with blocking looper/event delivery and platform timestamps. Inspect availability, minimum delay and reporting mode. Bound the event queue and retain calibration/decoder state incrementally. Handle light changes, noise, missed samples and end-of-message deadlines; do not periodically copy/scan a complete capture ring. A supported transmission rate follows from measured sensor behavior.

Exit: real light events and controlled optical peer transfer produce the declared text with error/timeout/cancel behavior; missing sensors return unsupported. Synthetic emulator events exercise binding/state only, not an optical link claim.

## V0: V.21 codec

Port continuous-phase two-tone generation and demodulation into named managed methods. Use the actual stream sample rate and fractional bit timing for non-integral rates, or reject unsupported rates explicitly. Validate rate/frequency/amplitude, allocation sizes, input bounds and finite values. Precompute recurrence coefficients; bound resynchronization work and define carrier/framing errors.

Treat donor 8N1, preamble/tail and CQ/K/R as separate application protocol choices. Establish channel frequencies/rates against ITU V.21; do not claim telephone interoperability or full duplex from a local half-duplex text demo.

Exit: independent signal/byte oracle, golden PCM/demodulation cases, both channel roles, split chunks, clock/phase offsets and noise cases at declared rates. Own encode/decode roundtrip alone is insufficient. Record throughput and buffer costs on all claimed backends.

## V1: AAudio device seam

Extend the existing diagnostic audio mechanism into owned input/output streams with stop/close, actual format/rate discovery, routing and lifecycle/error recovery. Trace RECORD_AUDIO admission and runtime consent for capture. Use bounded blocking worker reads/writes and handle partial frames without loss; wake cancellation through a documented stream/session mechanism. Streaming DSP consumes blocks, not interpreted samples. Avoid adding an audio middleware dependency.

Exit: waveform output preserves frame counts and durations; capture returns timestamped/bounded PCM; cancellation/background/window shutdown releases streams. Device/microphone availability and privacy state become explicit session errors.

## V2: peer transfer and optional acknowledgement

Start with one-way bounded payloads and streaming receive. Provide explicit length, framing and integrity error reporting; do not infer delivery from tone energy. Measure two-device acoustic transfer at supported rates and routes. Add an independently specified framed half-duplex acknowledgement state machine only afterward, with retry/timeout bounds and exact token/message types. Keep received data as data; do not execute decoded messages.

Exit: identical payload bytes reach the peer, corruption/truncation is detected, and cancellation restores the console while the app stays alive. Physical link evidence requires an actual transmitter/receiver pair.

## UI and packaging

A later retained pane can show compose/send/listen controls, status, captured levels and decoded text from the same commands. It uses shared focus/IME/menu/lifetime contracts. No browser presenter or agent feature is bundled. Package modules explicitly as optional admitted scripts/IL; record compressed APK/store costs and required permissions. Integration uses existing platform/UI/session ownership and a named graph action; no parallel build system.

No implementation, build or device test was performed for this work order.
