# Operational scripts

Copies of the job scripts that run from `~/.photo-sentinel/` on the Mac. That
directory is not in git, so this folder is the record of what actually ran.
Paths inside are hardcoded to that machine on purpose: these are not a product,
they are the log of a job. Copy them back with `cp scripts/*.sh ~/.photo-sentinel/`
after a fresh clone.

| script | what it does |
|---|---|
| `cycle.sh` | fetch -> upload -> release, repeating; empties the Bin itself when every item in it is a released asset |
|  | for a source set to follow its backups, also sends a copy to Google Photos before release (output in `~/.photo-sentinel/google-photos.log`; a failure never stops the backup) |
| `after-video.sh` | waits for the video job, starts screenshots only if it finished cleanly |
| `watch-video.sh` | every 10 min records that the job is ALIVE; the last line says when it died |

Never edit one of these in place while a job runs from it: bash reads scripts
incrementally. Write `x.sh.new` and `mv` it over.
