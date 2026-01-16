# Waveform Matcher
---

![WaveformMatcher](images/WaveformMatcher.png)

The **Waveform matcher** is a tool for reaper to match similar voice recordings from a different media item based on peak detection.

**Why?**
When doing remote recordings we record we record remotely  and already do edits on it but this recording often has problems like artifacts. so we have to manually find  the part from the clean recording and match it to the edited files. 

**how?**
For peak detection, we detect peaks in both the clean and the edited items, and then compare the edited peak pattern with the pattern following each peak in the clean file. In addition to comparing the absolute positions of the peaks, we also analyze the relative distances between peaks. This ensures the system still works when there are timing differences, for example due to network latency.

**Tips:**
- If a file is not managing to find a match try increasing its length as the peak-to-peak maching can have trouble with short filles

## How to use the Waveform Matcher
---

1. import your clean and edited files into reaper on separate tracks
2. Select the edited item(s) in reaper and then click **Load Edited Item(s)** button in the Waveform Matcher GUI. 
3. Select the clean item(s) in reaper and then click **Load Clean Item(s)** button in the Waveform Matcher GUI.
4. Configure peak detection setting
6. Click Match Waveforms -> now it will search the clean file for matches to the edited files and copy the best matches below each edited file. You can look at the log at the bottom to see details and potential errors.
7. When the progress bar has finished check the matches to make sure they are correct.

## Installation:
---
Reapack
1. Download and install Reapack for your platform here(also the user Guide): Reapack Download
2. go to Extensions->Reapack->Import Repositories paste the following link: Comming soon

Manual:
1. Download or clone the repository.
2. Add compareWaveform.lua as a new action in reaper, make sure the scripts folder is in the same location as compareWaveform.lua.
