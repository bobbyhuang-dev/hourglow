Import a folder of still images or a 24 Hour Wallpaper `.sundialScene` to build a timeline that follows local daylight.

## Organize the images

Use phase names in filenames, for example:

```text
MyScene/
  sunrise_1.heic
  sunrise_2.heic
  day_1.heic
  sunset_1.heic
  night_1.heic
```

Names containing `sunrise`, `morning`, `day`, `sunset`, `evening`, or `night` are recognized. A leading number, such as `01_sunrise_1.heic`, is supported. You can also organize images into phase subfolders, such as `sunrise/1.jpg` and `night/1.jpg`, when the filenames do not identify a phase.

A `.sundialScene` with several resolutions of the same image uses the largest available resolution. When some images have recognized phases, images whose phase cannot be determined are skipped and reported. If none have recognized phases, HourGlow sorts the images by name and divides them into four groups; explicit phase names give you more control over the result.

## Import and review

1. Open the timeline's **⋯** menu and choose **Import a 24-Hour Wallpaper…**.
2. Select the folder or `.sundialScene`.
3. Review the confirmation: **importing replaces the entire timeline**, rather than adding slots to it. Cancel if you want to keep the existing timeline.
4. After import, review the switch times and any skipped-file notice. Make sure your location is set so solar times can be calculated.

Imported images are copied under `~/Library/Application Support/HourGlow/Scenes/`. The schedule points at those copies. Keep your original image collection separately so you can import it again if needed.

Each phase can have a different number of frames. HourGlow divides the corresponding solar window evenly by that phase's frame count; it does not require one image per hour or exactly 24 images.

## Optional CLI

With the CLI installed on your `PATH`:

```bash
hourglow-cli import ~/Pictures/MyScene
```

This changes the saved schedule and can affect the active wallpaper when an engine is running. To experiment with a separate configuration, use a temporary directory:

```bash
HOURGLOW_HOME="$(mktemp -d)" hourglow-cli import ~/Pictures/MyScene
```

See [Troubleshooting](https://github.com/bobbyhuang-dev/hourglow/wiki/Troubleshooting) if files are skipped or the resulting times do not match your expectations.
