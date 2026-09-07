# AutoMiningDrones

Automatic asteroid selection and full-hold recall for launched mining drones in EveJS.

Version **1.1.0**. Supports the **EveJS 0.12.7.1** server files identified by the included compatibility checks. Windows PowerShell 5.1 or newer is required. Docker installations require Docker Desktop with Docker Compose. No additional Node.js installation is needed for the Docker installer.

## What it does

- Starts eligible, already-launched mining drones on nearby asteroids without requiring target locks.
- Offers **focus** (shared rock) and **spread** (separate rocks) targeting within **20 km of the ship**. This is a conservative search limit, not an extension to drone range.
- Retargets when a rock is depleted, including depletion by another drone or a mining laser.
- Respects private-site visibility and ore/ice drone compatibility.
- Uses EveJS's existing mining cycles, yields, inventory delivery, movement and drone-bay return handlers.
- Recalls enrolled mining drones and switches automation off when the preferred mining hold cannot fit another unit of the resource. Ordinary cargo space does not keep automation running when a dedicated mining hold is full. Ships without a dedicated mining hold use their cargo hold.

This is a server patch. Players use the normal client and can watch their drones work. Client files are not modified.

## Install

Download this repository using **Code > Download ZIP**, extract it, and rename the extracted `AutoMiningDrones-main` folder to `AutoMiningDrones`. Copy that entire folder into the existing `tools` folder in your EveJS installation. Keep the `payload` folder beside `Manage.ps1`.

```text
EveJS\
  package.json
  server\
  tools\
    AutoMiningDrones\
      Install.bat
      Uninstall.bat
      Status.bat
      Manage.ps1
      README.md
      payload\
```

1. Log out of the game before installation: applying the Docker patch restarts the game-server container.
2. Double-click **Install.bat**.
3. The installer detects the EveJS root automatically from `tools\AutoMiningDrones`. If the folder is elsewhere, it asks for the root containing `package.json`, `server`, and, for Docker, the Compose file. For an installation at the drive root, enter `E:\` rather than the Client folder.
4. Choose **D** for Docker or **N** for native Node.js.
5. For native installations, stop the server when prompted and type `STOPPED`. Start it normally after installation finishes.
6. For Docker, let the installer build the small patch image and recreate the server service. It waits for the healthcheck where one is configured.
7. Log in with a staff/GM character and test the commands below.

The installer checks the exact server-file contents before changing anything. Different releases and modified copies of those files are rejected rather than guessed at. A patch for another version must be prepared separately. Files elsewhere in the installation can be customized.

### Command-line installation

From this folder in PowerShell:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Manage.ps1 -Action Install -Root 'E:\' -Mode Docker
```

For a custom Compose file or service name:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Manage.ps1 -Action Install -Root 'E:\EveJS' -Mode Docker -ComposeFile 'E:\EveJS\compose.yaml' -Service server
```

Native server, after stopping it:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Manage.ps1 -Action Install -Root 'E:\EveJS' -Mode Native -ServerStopped
```

The Docker installer supports a single existing server container, with application files under `/app`, and the standard `node` image user. The server service must already exist. Layouts that bind-mount over the modified source files are rejected. No `compose down`, volume removal, database initialization or market-service recreation is performed.

## Usage

Undock, launch mining drones, and stay out of warp. Then enter:

```text
/autominingdrones on focus
/autominingdrones on spread
/autominingdrones status
/autominingdrones off
```

`/autominingdrones` and `/autominingdrones on` default to **focus**. The shorter forms `/autominingdrones focus` and `/autominingdrones spread` also work.

### Targeting modes

- **Focus:** all enrolled drones of the same mining type work on one compatible rock, then move together when it is depleted. The first drone selects its nearest rock that the group can use. Ore and ice drones form separate compatible groups.
- **Spread:** each enrolled drone selects its nearest compatible rock that is not already assigned to another enrolled drone. If there are fewer usable rocks than drones, the extra drones wait instead of sharing. They retry every five seconds. Other players' drones are not included in these reservations.
- Run either command again to change mode immediately. This replaces current mining orders and restarts unfinished mining cycles. `status` shows the current mode and the number waiting.

The command uses EveJS's existing staff-debug permission check. A normal character without that role cannot enable it.

- `on` enrolls your currently launched, idle or mining drones. It does not launch drones from the bay. Combat drones, assigned drones and drones returning home are not enrolled.
- No initial asteroid lock or manual mining order is needed.
- If no compatible rock is nearby, enrolled drones wait and search again every five seconds. Move within 20 km of a suitable rock, keeping the drones nearby.
- Any manual drone command, including Mine Repeatedly, Return and Orbit, Return to Drone Bay, Engage, Assist, Guard, Salvage, Abandon, Reconnect or Scoop, disables automation for your character. Use `on` again when you want to resume.
- `off` stops automatic orders; a current normal mining order continues. Use Return to Drone Bay to recall manually.
- A full mining hold triggers normal return-to-bay movement, then docking into the drone bay when within scoop range. Drones do not teleport. Normal bay-capacity and custody checks still apply.
- The full-hold check runs periodically and before automated mining-cycle delivery. “Full” includes insufficient room for a whole unit of the current resource.
- Automation is session-only. Warp, docking, changing ship, disconnecting or restarting the server ends it. Enable it again after relaunching drones.
- Newly launched drones are not enrolled automatically; run `on` again to refresh the group.
- Other non-depletion interruptions stop the affected drone's participation. Fix the problem and use `on` again.

## Status

Double-click **Status.bat**. The installation root is detected automatically, or you can run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Manage.ps1 -Action Status -Root 'E:\'
```

For native installs this verifies patched-file checksums. For Docker it checks that the server container uses the recorded patch image. In-game status reports whether your character's automation is enabled.

## Uninstall

1. Log out of the game.
2. Double-click **Uninstall.bat**. The same EveJS root is detected automatically.
3. For native installations, stop the server when prompted. The original files are restored byte-for-byte and the added runtime module is removed. Start the server normally afterwards.
4. For Docker, the server service is recreated using the original image captured at installation. The installer waits for its healthcheck.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Manage.ps1 -Action Uninstall -Root 'E:\'
```

Original files, image tags and installation records are retained under `.autominingdrones` in the EveJS root for recovery. The patch does not create game database records or alter character skills, mining yields, client files, configuration, or saved inventories. Ore mined while using it remains ordinary game inventory after uninstall.

## Updating this patch

If an earlier AutoMiningDrones version is installed, run **Uninstall.bat** first. Replace `tools\AutoMiningDrones` with this folder and run **Install.bat** again. Do not delete `.autominingdrones` or its backups to bypass an installed-state check. The included uninstaller also understands the version 1.0.0 installation record.

## EveJS updates and Docker maintenance

**Uninstall before updating EveJS**, then use a patch package compatible with the new version. Uninstall refuses to overwrite modified native files or replace an unexpected server image. Do not bypass that refusal by copying old source files over a newer release.

Docker uses a recorded Compose image override without editing your normal Compose file. Normal container restarts and the existing restart policy keep the patch. A later ordinary `docker compose up` or image replacement may select the unpatched image again. Use Status after maintenance. Do not switch the image while this installation is recorded as installed; uninstall first.

Keep the `.autominingdrones` folder and both locally tagged images until uninstall is complete. Do not prune the retained original image while the patch is installed.

## Troubleshooting

- **Compatibility check failed:** the source differs from the supported build. No source replacement is attempted. Uninstall any existing copy, or use a package matching your exact build.
- **Requires a staff/GM role:** use an account with the same permission required for EveJS staff-debug commands.
- **Launch idle mining drones first:** launch mining drones, cancel returning/assignment orders, and enable again. Drones must be within 20 km of your ship.
- **Waiting with no locks:** locks are unnecessary. Check for a compatible, non-depleted rock within 20 km of the ship and visible in the same site/room.
- **Returned earlier than expected:** the dedicated mining hold may have less than one unit of ore/ice space remaining, even when ordinary cargo has room.
- **Drones did not fit back into the bay:** the normal return command still enforces bay capacity. Free space and recall manually.
- **Docker startup failed:** the installer attempts to restore the original image. Read the error output and run Status. If it reports `recovery-required`, retain `.autominingdrones` and use the recorded original Compose override to restore the server; do not remove volumes.

This release should be tested with a small group of inexpensive mining drones before relying on it for longer sessions.
