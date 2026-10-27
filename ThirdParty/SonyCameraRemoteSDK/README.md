# Sony Camera Remote SDK (local installation)

Install your downloaded macOS SDK with:

```sh
python3 scripts/install-sony-sdk.py /path/to/CrSDK_Mac.zip
python3 scripts/generate_project.py
```

Sony headers and libraries stay local and are ignored by Git. A build with the
SDK installed links the core and embeds the SDK libraries in the host app's
Frameworks directory, preserving CrAdapter. The camera extension never links it.
Builds without the SDK still support HDMI capture and explain that Sony control
is unavailable. The command-line UI/test harnesses use this unavailable backend.

Integration and hardware qualification: [Sony control](../../docs/SONY_CONTROL.md).
