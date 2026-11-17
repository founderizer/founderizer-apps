# Contributing to Founderizer for Mac and iPhone

Issues and pull requests are welcome.

**How a change gets in.** This repository is a copy that we publish from our own repository, so we do not merge a pull
request here. We apply its change to our repository, run the tests, and publish the next copy with it. Then we close the
pull request with a link to that copy. The commit of that copy names you as co-author, so GitHub lists you as a
contributor. Under section 5 of the licence, what you send is under the Apache License 2.0.

**Before you send it.** Run `swift test` in the folder of this repository. The iPhone app's tests run in Xcode, as the
README says.

**A change to a view.** Read `UI-PATTERNS.md` first: it says how each view of the Mac app is drawn.
