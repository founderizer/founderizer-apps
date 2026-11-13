# Security

Founderizer for Mac holds the keys that operate your fleet, and Fleet Vault keeps logins and API keys on a Mac. A
security problem in these apps can let another person use them. If you find one, please tell us privately first, so
that we can fix it before other people know about it.

## Report a problem privately

Do not open a public issue, pull request or discussion about a security problem.

Report it with GitHub's private vulnerability reporting:

1. Open the **Security** tab of this repository.
2. Select **Report a vulnerability**.
3. Complete the form, and send it.

The form is also at <https://github.com/founderizer/founderizer-apps/security/advisories/new>. Only you and the
maintainers of this repository can see the report.

Put this information in the report:

- The version that you tested (**Founderizer › About Founderizer** on the Mac), or the commit of this repository.
- If you tested a build that you made yourself, say so. Our own builds have the signature of the Apple team
  `6EBZ756H9Q` (`README.md`, "Fleet Vault and the signing team").
- The steps that show the problem.
- What an attacker can do with the problem.
- A proof of concept, if you have one.

Do not put a real password, key or token in a report, also not one of your own. Use an example value.

## What happens after a report

1. We read the report, and we answer you in the report.
2. We examine the problem. If we need more information, we ask you in the report.
3. If it is a security problem, we make the fix in our own repository, we test it, and we publish it in a new
   version of the apps. Then we publish a new copy of this repository (`README.md`, "Changes from outside").
4. After the new version, we publish a security advisory in this repository. The advisory tells what the problem
   was, which versions have it, and which version fixes it. If you agree, the advisory gives your name.
5. If it is not a security problem, we tell you why in the report.

Please keep the problem private until we publish the advisory.

## Which versions get fixes

We fix only the newest version of each app. On a Mac, **Settings › Updates** installs it. Fleet Vault is inside the
Mac app, and its own updater installs a newer Fleet Vault only when the new build has our team's signature
(`Vault/update.zsh`). If you build the apps yourself, build them again from the fixed source.

## What this policy covers

- Founderizer for Mac, its setup service, Founderizer Installer, Fleet Vault, and Founderizer for iPhone.
- The hub, the helpers on the servers and the central vault are in <https://github.com/founderizer/founderizer>.
  Report a problem in them there.
- If you do not know which repository a problem belongs to, report it in either one.

## How the vault keeps secrets

<https://github.com/founderizer/founderizer/blob/main/VAULT.md> tells what the vault protects, how it protects it,
what it does not protect, and what the owner of a fleet must do.
