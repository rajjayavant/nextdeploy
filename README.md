# nextdeploy

Deploy a Next.js app to a fresh Ubuntu EC2 server with a single command.

> **Status:** early / idea stage. Nothing is implemented yet — this repository currently holds the concept and scope.

## The idea

Getting a Next.js app running on a bare Ubuntu EC2 instance is a repetitive chore: SSH in, install Node, install a process manager, clone the repo, build, configure a reverse proxy, keep it alive across reboots. It's the same sequence every time, and it's easy to get a step subtly wrong.

`nextdeploy` aims to collapse that into one command pointed at a fresh server.

```
nextdeploy <ssh-target> <git-repo-url>
```

## What it will do

- Install the required dependencies on the server (Node.js, a process manager, a web server)
- Clone the user's repository
- Build and run the app under [PM2](https://pm2.keymetrics.io/) so it survives crashes and reboots
- Configure [Nginx](https://nginx.org/) as a reverse proxy in front of the app

## Assumptions

- A **fresh Ubuntu** EC2 instance (no prior setup expected)
- SSH access to that instance
- A Next.js application in a Git repository

## Not yet decided

Implementation language, CLI interface, configuration format, TLS/certificate handling, environment variable management, and redeploy/rollback behavior are all still open. Suggestions welcome via issues.

## Contributing

The project is at the stage where discussion is more useful than code. If you have opinions on scope or approach, open an issue.

## License

MIT
