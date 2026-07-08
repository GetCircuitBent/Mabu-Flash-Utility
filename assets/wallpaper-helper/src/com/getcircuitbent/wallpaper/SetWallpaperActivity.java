package com.getcircuitbent.wallpaper;

import android.app.Activity;
import android.app.WallpaperManager;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.os.Build;
import android.os.Bundle;
import android.util.Log;

/**
 * Sets the bundled GCB image as the home (and, on API 24+, lock) wallpaper,
 * then finishes immediately. No UI (Theme.NoDisplay). Launched once by the
 * -Branded flash phase; safe to run again (idempotent).
 *
 * Uses setBitmap (not setResource) so the image is COPIED into the wallpaper
 * store -- the wallpaper then survives uninstalling this helper, so the flash
 * can remove it afterward and leave a clean device.
 */
public class SetWallpaperActivity extends Activity {
    private static final String TAG = "GCBWallpaper";

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        try {
            WallpaperManager wm = WallpaperManager.getInstance(this);
            Bitmap bmp = BitmapFactory.decodeResource(getResources(), R.drawable.gcb_wallpaper);
            if (Build.VERSION.SDK_INT >= 24) {
                // allowBackup=true; FLAG_SYSTEM = home, FLAG_LOCK = lock screen
                wm.setBitmap(bmp, null, true,
                        WallpaperManager.FLAG_SYSTEM | WallpaperManager.FLAG_LOCK);
            } else {
                wm.setBitmap(bmp);
            }
            Log.i(TAG, "GCB wallpaper set OK (copied into wallpaper store)");
        } catch (Throwable t) {
            Log.e(TAG, "failed to set wallpaper", t);
        }
        finish();
    }
}
