# Cloud APK Build — Beginner Guide (Bangla)

এই package-এ GitHub Actions workflow দেওয়া আছে। Local PC-তে Flutter/Android Studio install না করেও GitHub-এর cloud runner দিয়ে APK build করা যাবে।

## কী লাগবে
- একটি GitHub account
- GitHub Desktop (সহজ upload-এর জন্য; Flutter/Android Studio লাগবে না)
- Internet

## Build flow
1. GitHub Desktop দিয়ে নতুন repository তৈরি করো।
2. এই project folder-এর সব file সেই repository folder-এ copy করো।
3. GitHub Desktop থেকে Commit এবং Publish repository করো।
4. GitHub website-এ repository > Actions > Build Android APK খুলো।
5. Run workflow চাপো।
6. Build green হলে run page-এর Artifacts থেকে `gemma-vision-bangla-apk` download করো।
7. Downloaded artifact ZIP extract করলে `app-release.apk` পাবে।

Workflow Flutter 3.32.5 এবং Android NDK 27.0.12077973 pin করে, project metadata/build config-এর সাথে মেলানোর জন্য।
