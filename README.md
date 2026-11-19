# pnpm Monorepo CI/CD
A simple CI/CD setup for a pnpm monorepo that allows you to automatically detect which workspace packages have changed. On every push [this workflow](.github/workflows/deploy.yml) will run and automatically run the deploy script for any changed workspace packages. Only packages which have been modified will be deployed. Changes to dependencies count, so if a shared workspace package is changed only the packages that depend on it will be re-deployed.

## Installation
To install this into your own project, I'd recommend just copying the [change detecting script](scripts/ci/changed.sh) and taking what you need from [the workflow](.github/workflows/deploy.yml). The deploy workflow is not meant to be used as is in other projects, it's just supposed to serve as an example of how to use the changed script. The script can be used in any pnpm project, it reads all the workspace packages automatically and can be configured with custom excludes.

To get a hands on example you can fork this and make commits to the `main` branch to run the deploy workflow. If you make changes to the repo root, everything will be marked as changed. If you change something in `apps/web/` it will only redeploy the website. If you change something in `packages/logs/`, it will re-deploy `apps/mobile/`, `infra/` and `packages/logs/`.
