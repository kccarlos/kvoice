# Security policy

## Reporting a vulnerability

Please report security problems **privately**, not in a public issue or pull
request.

Use GitHub's private vulnerability reporting: open the
[Security tab](https://github.com/kccarlos/kvoice/security) of this repository
and choose **Report a vulnerability**. Only the maintainers can see the report.

Please include:

- what an attacker could do, and what they need first (local access, a
  malicious endpoint, a crafted model file, and so on);
- steps to reproduce, and the kvoice version and edition (direct download or
  Mac App Store) and macOS version;
- any proof of concept you have.

You can expect an acknowledgement within a week. We will keep you informed
while we work on a fix, agree a disclosure date with you, and credit you in
the advisory unless you prefer not to be named.

## Supported versions

Only the latest release receives security fixes. Before the first release,
only the `main` branch is supported.

## Scope

Examples of what we want to hear about:

- anything that sends audio, transcripts, clipboard or selected text, or API
  keys somewhere the user did not choose (see [PRIVACY.md](PRIVACY.md) for
  what is supposed to leave the Mac);
- an API key written anywhere other than the secrets file, or readable by
  other users;
- transcript text, audio or secrets appearing in the diagnostics log;
- a way to make kvoice load a speech model that does not match its pinned
  manifest;
- text inserted into a different app or field than the one that was focused,
  or into a password field;
- a prompt-injection path from a transcript, the clipboard or selected text
  that makes kvoice do something other than return text.

Out of scope: problems in the AI provider you configured, in macOS, or in a
speech model's own output, and anything that needs the attacker to already
control your user account.
