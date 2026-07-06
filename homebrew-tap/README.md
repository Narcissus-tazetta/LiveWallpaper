# homebrew-tap

Homebrew tap for [LiveWallpaper](https://github.com/Narcissus-tazetta/LiveWallpaper).

## Install

```bash
brew install --cask narcissus-tazetta/tap/livewallpaper
```

## Update

```bash
brew update
brew upgrade --cask livewallpaper
```

## Repository setup (maintainers)

This directory is synced to the `Narcissus-tazetta/homebrew-tap` GitHub repository on each release.
Create the tap repository once if it does not exist:

```bash
gh repo create Narcissus-tazetta/homebrew-tap --public --description "Homebrew tap for LiveWallpaper"
```

The release workflow updates `Casks/livewallpaper.rb` automatically when `HOMEBREW_TAP_TOKEN` is configured.
If the secret is not set, the workflow falls back to `GITHUB_TOKEN` for pushes to the same organization.
