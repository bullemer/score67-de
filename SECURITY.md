# Security

Please report suspected vulnerabilities privately using [GitHub private vulnerability reporting](https://github.com/bullemer/score67-de/security/advisories/new). Include the affected version, reproduction steps, and expected impact. Do not post credentials or a working exploit against the live service in a public issue.

Keep production `.env` files, SSH private keys, SMTP credentials, scoreboard PINs, display tokens, Wi-Fi passwords, and database dumps out of Git. The files in `deploy/.env.example` contain placeholders only; test database credentials belong exclusively to disposable test databases.

Pull requests and production deployments run a redacted secret scan of Git history. These checks help detect accidental leaks; they do not replace careful review. If a real credential is exposed, revoke or rotate it before removing it from files or history.
