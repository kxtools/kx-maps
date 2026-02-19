# KX-Maps

Official repository of custom route files created for the **[premium KX Trainer Pro](https://kxtools.xyz/kx-trainer-pro)**. These community-made files help you explore maps more efficiently in Guild Wars 2!

## Usage
To use these files, you need an active license for the **[premium version of KX Trainer Pro](https://kxtools.xyz/kx-trainer-pro)**. Once you have it, simply clone this repository, replace your local `Maps` folder with the one from here, and load the desired file in the utility to start exploring.

## Contributing
Pull requests are welcome. If you think that there is something missing you can always make your own custom routes using the KX Trainer Pro map-making system and open a pull request. For major changes, please open an issue first to discuss what you would like to change.

## Map Requests
If you want us to add a specific file, please simply open an issue with the label "request." Before you do that, you should make sure that your requested route file doesn't exist yet!

## Contact & Community
You can contact us on our [Discord server](https://discord.gg/z92rnB4kHm) for any questions or support.

Discover more tools and get your KX Trainer Pro license at **[kxtools.xyz](https://kxtools.xyz)**.

## Validation
Run before push:
```powershell
pwsh -File scripts/checks/validate-json.ps1
pwsh -File scripts/checks/check-name-alignment.ps1
pwsh -File scripts/checks/check-filename-style.ps1
```

These checks also run in GitHub Actions on pull requests and pushes to `main` (`json-validation`).

## Acknowledgments
* [Bloodmagicball](https://github.com/Bloodmagicball) - for being the first person who bought KX Trainer, making most of the route files, and helping our community over the years ❤
