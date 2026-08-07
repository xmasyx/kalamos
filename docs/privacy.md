# Verifying the privacy claim yourself

## Verifying the privacy claim yourself

Do not take the section above on faith — it is a claim about software you did not
write.

- **Cut the network.** Turn Wi-Fi off after the first run. Dictation, cleanup,
  translation and Edit Mode all keep working.
- **Watch the connections.** Point Little Snitch, LuLu or
  `lsof -i -p $(pgrep -x Kalamos)` at it and dictate. After the model download
  there is nothing to see.
- **Read exactly what it stored about you.** This prints the rolling history in
  plain text, so you can see there is nothing else hiding in there:

  ```sh
  plutil -extract transcriptHistory raw -o - \
    ~/Library/Preferences/com.kalamos.app.plist | base64 -d
  ```

  Everything else in that file is settings you chose yourself: trigger key,
  models, vocabulary, correction rules.
- **Read the code.** `grep -rn "https://" Sources/` returns nothing: the app's own
  source contains no URLs at all. The only endpoints in play are the model
  downloads inside WhisperKit and MLX, both of which you can read too.

