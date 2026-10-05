# Hidden Word

ESV Bible verse memorization: phrase chunks, word fading, first-letter typing, full recall, and spaced review.

Open it at https://richardpulliam-hue.github.io/Bible-Verse-Memorization-App/

Verses are listed in `MY_VERSES` near the top of the script in `index.html`.

Scripture quotations are from the ESV® Bible (The Holy Bible, English Standard Version®), © 2001 by Crossway, a publishing ministry of Good News Publishers. Used by permission. All rights reserved.

## Family sign-in (optional)

Family sign-in syncs each person's progress across devices and adds a family board. It uses a free Supabase project:

1. Create a project at supabase.com.
2. In the project, open SQL Editor, paste all of `supabase-setup.sql`, and click Run.
3. Put the Project URL and the publishable (anon) key into `CLOUD` near the top of the script in `index.html`.

Until `CLOUD` is filled in, the app runs on each device on its own, with no sign-in.
