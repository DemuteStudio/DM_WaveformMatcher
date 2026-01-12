# Waveform Matcher
---

![[WaveformMatcher.png]]

The **Waveform matcher** is a tool for reaper to match similar voice recordings from a different media item based on peak detection and Speech-to-text(STT)

**Why?**
When doing remote recordings we record we record remotely  and already do edits on it but this recording often has problems like artifacts. so we have to manually find  the part from the clean recording and match it to the edited files. 

## How to use the Waveform Matcher
---

1. Select the edited item(s) in reaper and then click **Load Edited Item(s)** button in the Waveform Matcher GUI. 
2. Select the clean item(s) in reaper and then click **Load Clean Item(s)** button in the Waveform Matcher GUI.
3. Configure peak detection setting
4. Optional: Configure STT settings: select the STT engine that you want to use and fill its required arguments. STT should increase accuracy but it is also quit accurate without, and it will slow down the process significantly.
5. Click Match Waveforms -> now it will search the clean file for matches to the edited files and copy the best matches below each edited file. You can look at the log at the bottom to see details and potential errors.
6. When the progress bar has finished check the matches to make sure they are correct.
