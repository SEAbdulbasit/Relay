# Verify Relay’s closed-lid Morning Brief on a MacBook

This test checks that a Relay-owned wake starts and finishes one scheduled brief while the lid stays closed, then lets the Mac sleep again. Use an Apple silicon MacBook connected to power and a macOS test account with a local model and a folder containing only test files. Disconnect external displays and docks that can keep the Mac awake in clamshell mode.

## Prepare the signed build

From the Relay repository, build and sign a local release candidate. Replace the placeholder with the SHA-1 fingerprint of your Developer ID Application identity.

```bash
bash Scripts/build-app.sh release
RELAY_RELEASE_IDENTITY='<Developer ID Application SHA-1>' python3 Scripts/release-app.py --prepare
```

Open the exact signed `Relay.app` printed by the script. Keep that bundle at a stable path while its helper is registered. If the candidate is being distributed to another Mac, use the notarized and stapled release instead. Check the signed candidate before opening it.

```bash
relay_candidate='/absolute/path/to/signed/Relay.app'
/usr/bin/codesign --verify --deep --strict "$relay_candidate"
/usr/bin/codesign -d --verbose=4 "$relay_candidate" 2>&1 | /usr/bin/grep -E 'Identifier=|TeamIdentifier=|Authority='
/usr/bin/plutil -lint "$relay_candidate/Contents/Library/LaunchDaemons/dev.relay.assistant.preparation-wake.plist"
```

Record the candidate path, bundle version, macOS version, Mac model, time zone and power source with the results.

## Prepare the test

1. In **Relay → Settings → Knowledge**, add the test folder. Under **Proactive Briefings**, turn on **Enable proactive suggestions from indexed sources**.
2. Expand **Morning Brief schedule**. Turn on **Prepare a daily brief**, choose a local time roughly ten minutes ahead, and select the test folder under **Refresh sources**. Use a fresh local day or test account if today’s scheduled run was already handled.
3. Expand **Wake this Mac for preparation**. Click **Set up managed wake**. If macOS requests approval, click **Open Login Items** and approve the helper in System Settings. Return to Relay and click **Check macOS wake schedule**.
4. Turn on **Allow scheduled preparation with the lid closed**. Confirm Relay shows that macOS accepted the selected wake time. Capture the following read-only baseline.

   ```bash
   /bin/date '+%Y-%m-%d %H:%M:%S %z'
   /usr/bin/pmset -g batt
   /usr/bin/pmset -g sched
   /usr/bin/pmset -g | /usr/bin/grep SleepDisabled
   ```

   The queue should contain one future wake with owner `dev.relay.assistant.managed-preparation.<uid>` at the selected time. `SleepDisabled` should be `0` before the brief starts. Record unrelated queue entries so they can be compared after the test.
5. Add a new Markdown file inside the selected folder after indexing has completed. Give it a unique action line, for example `TODO: Review closed-lid fixture 20261111-A`. Check that this marker is absent from the current Morning Brief. Then leave Relay running.

## Run and evaluate

1. Close the lid several minutes before the scheduled time and record when you closed it. Leave it closed until at least five minutes after the scheduled wake, or up to the 20-minute run limit if the fixture includes a slow model draft. Record when you reopen it. Avoid any interaction that could wake the test Mac during that interval.
2. Immediately collect the schedule, sleep setting and power log. If the schedule state exists in the default location, capture its modification time before opening the Morning Brief.

   ```bash
   /bin/date '+%Y-%m-%d %H:%M:%S %z'
   /usr/bin/pmset -g sched
   /usr/bin/pmset -g | /usr/bin/grep SleepDisabled
   /usr/bin/pmset -g log | /usr/bin/tail -n 250
   relay_preparation_state="$HOME/Library/Application Support/Relay/preparation-schedule.json"
   /usr/bin/stat -f 'Modified %Sm' -t '%Y-%m-%d %H:%M:%S %z' "$relay_preparation_state"
   /usr/bin/plutil -extract lastOutcome raw -o - "$relay_preparation_state"
   ```

3. In Relay, capture **Morning Brief schedule** showing **Last prepared**, and open **Morning Brief** from the workspace toolbar. Confirm that the unique marker appears once with the expected test source. Check that revisiting the schedule or relaunching Relay on the same local day does not produce a second run.
4. A pass requires a sleep entry before the due time, a matching wake or dark wake while the lid was closed, and a recorded preparation completion before the lid reopened. The state should show `prepared`, the brief should contain the marker once, and the power log should show the Mac returning to sleep before the lid reopened. Confirm `SleepDisabled 0` and compare unrelated wake entries against the baseline. A wake record followed by the first preparation only after opening the lid leaves closed-lid completion unverified.

## Verify cancellation and recovery

Run these checks on separate scheduled runs or fresh test days when a fresh brief is required.

- **Change the time.** Before the original due time, choose another time far enough ahead. Confirm the old Relay-owned entry disappears and one new entry appears while unrelated entries remain.
- **Stop a run.** Use a test source or local draft that stays active long enough to observe the helper’s awake-hold status. Click **Stop preparation**. Confirm `SleepDisabled 0` and no completed brief from that run.
- **Quit Relay.** With an owned future wake pending, quit Relay and check that its pending wake disappears. Relaunching with the schedule enabled may arm a new wake.
- **Force Quit during a hold.** In a separate run with `SleepDisabled 1` confirmed after Relay acquired the hold, Force Quit Relay. Keep the helper installed. Confirm sleep is restored and the owned wake disappears. Allow up to a minute for the helper’s heartbeat watchdog and next check.
- **Remove the helper.** In **Wake this Mac for preparation**, click **Remove wake helper**. Wait for **Managed wake is off**. Confirm there is no Relay-managed wake, `SleepDisabled` is `0`, and unrelated entries remain.

If sleep restoration or wake cancellation is pending, keep the signed app and helper in place, open the lid, and return to Relay. Leave the Mac connected to power while retrying **Remove wake helper** so the helper can confirm restoration before unregistering. If the helper is awaiting approval, use **Open Login Items** to restore its access first. Preserve the signed candidate and the before/after power logs for diagnosis if restoration cannot be confirmed.
