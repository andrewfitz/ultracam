# Security Policy

## Supported versions

MonitorKit is pre-1.0. Security fixes go into the latest release only.

| Version | Supported |
| --- | --- |
| 0.1.x | Yes |
| < 0.1 | No |

## Reporting a vulnerability

Please don't report security vulnerabilities in public issues, discussions or pull requests.

Report them privately through GitHub's private vulnerability reporting instead:

1. Open the repository's [Security tab](https://github.com/andrewfitz/MonitorKit/security).
2. Choose **Report a vulnerability**, or go straight to [the new advisory form](https://github.com/andrewfitz/MonitorKit/security/advisories/new).

Please include:

- the MonitorKit version or commit
- the macOS or iOS version, the Xcode version and the device or GPU
- the affected module and API
- steps to reproduce, ideally with a minimal input such as a `.cube` file, frame dimensions or pixel format
- the impact you see, for example a crash, an out-of-bounds GPU read or write, memory corruption or a hang

Relevant areas include parsing untrusted input (`.cube` LUT files, pixel buffer attachments and frame metadata), bounds on GPU buffer and texture access, and any route from host-supplied data to undefined behaviour.

## What happens next

- The report will be acknowledged within 7 days.
- The maintainer will confirm the issue, agree a fix and a disclosure timeline with you, and keep you updated.
- The fix is released as a patch version, and a GitHub Security Advisory is published, credited to you unless you would rather stay anonymous.

This is a volunteer project, so these are goals rather than guarantees.
