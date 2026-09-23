# MIME comparison harness

This standalone package is for development only.
Its dependency is the previous production parser at the pinned revision.
It is not part of Envelope's production or test dependency graph.
Use synthetic fixtures only.

Run these commands from the Envelope repository:

```sh
swift run --package-path Tools/MIMEComparison Compare Tests/MIMETests/Fixtures/*.mime
python3 Tools/MIMEComparison/compare.py Tests/MIMETests/Fixtures/*.mime
swift test
python3 Tools/fuzz.py --count 1000000
```

The Swift tests check reviewed expectations.
The comparison programs report independent parser output.
See `Documentation/MIME.md` for the decisions for each known difference.
Neither agreement nor majority vote determines correctness.
The fuzz runner uses a fixed seed, AddressSanitizer, and a subprocess timeout.
It saves the current synthetic mutation in `.build-asan/mime-fuzz-current.mime`.
A failure retains that file and copies it to the regression corpus.
A successful run removes it.
