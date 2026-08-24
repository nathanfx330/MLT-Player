<!-- THIRD_PARTY_NOTICES.md -->

# Third-party licensing notices

MLT Player's own source code is licensed under the MIT License in [`LICENSE`](LICENSE).
That license applies to code authored for this repository; it does not replace or
supersede the licenses of third-party libraries, frameworks, codecs, plugins, or
system packages used with the application.

This file is a practical distribution note, not legal advice. Anyone shipping a
binary build should review the licenses and build configuration of the exact
third-party components included in that distribution.

## MLT Framework

MLT Player links dynamically to the installed MLT 7 framework through
`pkg-config` (`mlt-framework-7`). The MLT project states that its framework and
client libraries are licensed under the GNU Lesser General Public License v2.1
(LGPL-2.1), while MLT modules/plugins can use different licenses.

MLT is configurable at build time. In the MLT 7.22.0 source tree, disabling the
project's `GPL` option disables GPL-gated components including `normalize`,
`plusgpl`, Qt/Qt6, `resample`, `rubberband`, `vid.stab`, and `xine`. Other
modules and their dependencies have their own licensing terms, so an installed
or bundled MLT build should be audited rather than assumed to be LGPL-only.

Upstream references:

- https://www.mltframework.org/docs/copyrightpolicy/
- https://www.mltframework.org/features/
- https://github.com/mltframework/mlt

Dynamic linking is useful for LGPL compliance and lets users obtain or replace
system MLT independently, but dynamic linking by itself is not a complete
license-compliance statement. Binary distributors remain responsible for the
notices, license texts, source/relinking obligations, and other requirements
that apply to the exact MLT libraries and modules they distribute.

## FFmpeg and codec libraries

MLT's `avformat` module uses FFmpeg. FFmpeg states that most of its code is
licensed under LGPL-2.1-or-later, but enabling optional GPL components with
`--enable-gpl` changes the effective FFmpeg build to GPL-2.0-or-later. External
libraries can also affect the effective license of an FFmpeg build.

MLT Player's **H.264 Delivery** preset requests `libx264`. FFmpeg documents
`libx264` as a GPL-compatible external library that requires an FFmpeg build
configured with `--enable-gpl`. A system capable of satisfying that preset may
therefore be using a GPL-enabled FFmpeg build. This does not change the MIT
license text covering MLT Player's own source code, but it can matter when
redistributing a binary together with the multimedia stack.

FFmpeg also documents `--enable-nonfree` combinations that are not
redistributable. Distributors should inspect the actual FFmpeg build they plan
to ship rather than relying on the package name alone.

Upstream reference:

- https://ffmpeg.org/doxygen/trunk/md_LICENSE.html

A useful local audit command is:

```bash
ffmpeg -buildconf
```

## Distribution checklist

Before distributing a prebuilt MLT Player package or bundle:

1. Identify the exact MLT framework version and the MLT modules/plugins being
   packaged or expected to load.
2. Identify the exact FFmpeg build and its configure flags, including GPL,
   version-3, nonfree, and external codec-library options.
3. Include the required third-party copyright notices and license texts.
4. Satisfy any source-code, relinking/replacement, or other distribution
   obligations imposed by the third-party licenses that actually apply.
5. Re-run the audit whenever the packaged multimedia stack changes.

The repository intentionally does not claim that every possible MLT/FFmpeg
runtime combination is covered only by MIT or LGPL terms.
