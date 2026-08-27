# SVGA Protobuf sources

`svga.proto` and `svga.pb.swift` are copied without schema changes from
[SVGAPlayer 2.5.8](https://github.com/svga/SVGAPlayer-iOS), pinned to commit
`98cb1825cfbea8506e979d28d0a9269dcf12c20a`.

The upstream project distributes these files under Apache License 2.0. The
generated Swift binding is committed as source and remains internal to the
`LYSVGAPlayer` module. No generated Objective-C source or codegen executable is
included.
