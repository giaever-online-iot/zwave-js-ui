# Label PR Build Status Action

This GitHub Action automatically labels pull requests based on the presence of build artifacts (snap and log files).

## Labeling Logic

The action checks for `.snap` and `.log` files in the artifacts directory and applies labels according to the following rules:

| Condition | Label | Color | Description |
|-----------|-------|-------|-------------|
| snap-file missing | `build/failed` | ![#b60205](https://via.placeholder.com/15/b60205/000000?text=+) `#b60205` | One or more builds failed |
| log-file missing | `build/unknown` | ![#f9c513](https://via.placeholder.com/15/f9c513/000000?text=+) `#f9c513` | One or more builds unknown |
| both exist | `build/passed` | ![#0e8a16](https://via.placeholder.com/15/0e8a16/000000?text=+) `#0e8a16` | All builds passed |

## Inputs

- `github-token` (required): GitHub token for API access
- `pr-number` (required): Pull request number to label
- `artifacts-path` (required): Path to the directory containing downloaded artifacts (default: `.`)

## Usage

```yaml
- name: Label PR based on build status
  uses: ./.github/actions/label-pr-build-status
  with:
    github-token: ${{ secrets.GITHUB_TOKEN }}
    pr-number: ${{ steps.get-pr.outputs.pr-number }}
    artifacts-path: .
```

## How It Works

1. The action recursively scans the `artifacts-path` directory for `.snap` and `.log` files
2. Based on the presence of these files, it determines the appropriate label
3. If the label doesn't exist in the repository, it creates it with the predefined color and description
4. It removes any other build status labels (`build/passed`, `build/failed`, `build/unknown`) before applying the new one
5. Finally, it applies the determined label to the PR

## Dependencies

- `@actions/core` - GitHub Actions core library
- `@actions/github` - GitHub Actions GitHub client library
- Node.js 20
