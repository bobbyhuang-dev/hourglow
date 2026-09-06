## Choose a trigger

Each enabled slot pairs a trigger with a system aerial wallpaper or a local image. HourGlow resolves the most recent trigger, including the preceding day when needed, and schedules the next switch.

| Trigger | Use it for | Example |
| --- | --- | --- |
| Clock time | A fixed local time each day | Day wallpaper at 09:00 |
| Sunrise or sunset | A time relative to the local sun, with an offset | Evening wallpaper 30 minutes before sunset |
| Solar phase | Several frames distributed across a daylight or night window | Three sunrise images in an imported set |

The first-launch Tahoe preset uses sunrise for Morning, 09:00 for Day, 30 minutes before sunset for Evening, and 60 minutes after sunset for Night. These are editable slots, not fixed rules.

Sun times are calculated locally. Solar phases distribute frames across today's sunrise, day, sunset, and night windows; their actual times change with the date and location. [Importing wallpaper sets](https://github.com/bobbyhuang-dev/hourglow/wiki/Importing-Wallpaper-Sets) explains how to create these slots.

## Edit and save

Click a slot to edit it, choose a trigger and wallpaper, then click **Apply**. Slot edits are drafts until Apply; returning to the timeline discards unapplied changes. Choosing a wallpaper on another page preserves the draft. Deletion has an inline confirmation and takes effect after confirmation.

Settings such as language and location take effect immediately. The daylight bar is a status graphic showing today's sun conditions and trigger positions; use the slot list to edit the schedule.

## Automatic and fixed location

- **Automatic:** New configurations enable automatic location. With permission, the app checks on launch and at relevant events, including daily refreshes and time-zone changes. Failed checks keep the last successful location; the location page shows the last successful check.
- **Fixed:** Choose a city or enter coordinates to keep a fixed location. Existing saved coordinates remain fixed on upgrade because older configurations did not record how they were obtained.
- **Time-zone fallback:** Without saved coordinates, the app tries a permission-free estimate from your time zone. If coordinates or a sun event cannot be resolved, check the timeline for unavailable solar times and use clock triggers where appropriate.

The CLI can save a city or coordinates, but cannot request a system location fix. Setting a CLI location disables automatic location. Reverse geocoding supplies a readable name; it does not replace the saved coordinates.

## Manual wallpaper changes, sleep, and pause

If you pick a wallpaper in System Settings, that manual choice lasts until the next scheduled switch. Launching the app, waking the Mac, or changing time zone without crossing a trigger does not overwrite a manual choice. Crossing a trigger, including sleeping through one, lets the schedule take over again. Resuming from pause also resumes scheduled switching.

The engine responds to wake, clock changes, time-zone changes, and day rollover. It schedules a timer for the next trigger rather than polling the wallpaper.

HourGlow changes the desktop and screen saver together. Per-display, per-Space, and separate screen saver scheduling are outside the current scope; see the [non-goals](https://github.com/bobbyhuang-dev/hourglow/blob/main/CONTRIBUTING.md#non-goals).

Place-name searches stay offline while the built-in city list has matches. Otherwise the app
queries Apple MapKit after a short typing pause (at least two characters). The CLI also uses
MapKit when its offline lookup has no match. Current-location fixes use macOS Location Services;
MapKit may reverse-geocode the coordinates to supply a readable name. No Nominatim requests are made.
