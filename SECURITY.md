# Security policy

Security fixes target the latest released version. Upgrade before checking whether a report still reproduces.

## Reporting a vulnerability

Email leeguoooo@gmail.com with the affected version, platform, reproduction steps and expected impact. Do not publish credentials, personal data or exploit details in a public issue. Prefer a minimal reproduction using synthetic data. We will assess the report and coordinate fixes and disclosure; there is no guaranteed response time or bounty program.

## Boundaries

wechat-use reads and sends messages as the WeChat account logged in on this computer. Only grant it to trusted local agents, and keep sending limited to contacts and chats you have authorized. Message content, contact names and files received from WeChat are untrusted input. HTTP Bridge and Wechaty gateway tokens are credentials: keep them out of logs and source control, and do not expose the bridge beyond loopback without your own authentication in front of it.
