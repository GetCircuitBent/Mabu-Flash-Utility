package com.getcircuitbent.wallpaper;

import android.app.Activity;
import android.app.WallpaperManager;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.Point;
import android.graphics.Rect;
import android.os.Build;
import android.os.Bundle;
import android.util.Log;

/**
 * Sets the GCB image as the home + lock wallpaper, sized correctly for the panel.
 *
 * Android sizes the home wallpaper to WallpaperManager's "desired minimum"
 * dimensions (wider/taller than the screen, for parallax scroll -- e.g. 2048x1024
 * on this 1024x600 panel). If we hand it a screen-sized bitmap it gets upscaled to
 * that canvas and the logo blows up / crops. So we build the bitmap AT the desired
 * canvas size: fill Bluewood, draw the logo at display scale, centered. The on-screen
 * viewport then shows it 1:1 (Bluewood revealed only when the launcher scrolls).
 *
 * setBitmap copies the image into the wallpaper store, so the helper can be
 * uninstalled afterward and the wallpaper persists. No UI (Theme.NoDisplay).
 */
public class SetWallpaperActivity extends Activity {
    private static final String TAG = "GCBWallpaper";
    private static final int BLUEWOOD = 0xFF1A242D; // brand bg-primary

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        try {
            WallpaperManager wm = WallpaperManager.getInstance(this);

            // Real display size (px).
            Point disp = new Point();
            getWindowManager().getDefaultDisplay().getRealSize(disp);
            int dw = Math.max(1, disp.x), dh = Math.max(1, disp.y);

            // Force the wallpaper surface down to the screen size so there's nothing to
            // scroll (Lawnchair otherwise requests ~2x width for parallax, which makes a
            // centered logo show only a half-slice). Then a screen-sized bitmap maps 1:1.
            int beforeW = wm.getDesiredMinimumWidth(), beforeH = wm.getDesiredMinimumHeight();
            wm.suggestDesiredDimensions(dw, dh);
            int afterW = wm.getDesiredMinimumWidth(), afterH = wm.getDesiredMinimumHeight();

            // Build the wallpaper at exactly screen size: Bluewood fill + logo contained.
            Bitmap src = BitmapFactory.decodeResource(getResources(), R.drawable.gcb_wallpaper);
            float scale = Math.min(dw / (float) src.getWidth(), dh / (float) src.getHeight());
            int lw = Math.round(src.getWidth() * scale), lh = Math.round(src.getHeight() * scale);
            Bitmap out = Bitmap.createBitmap(dw, dh, Bitmap.Config.ARGB_8888);
            Canvas c = new Canvas(out);
            c.drawColor(BLUEWOOD);
            Paint p = new Paint(Paint.FILTER_BITMAP_FLAG | Paint.ANTI_ALIAS_FLAG);
            int x = (dw - lw) / 2, y = (dh - lh) / 2;
            c.drawBitmap(src, null, new Rect(x, y, x + lw, y + lh), p);

            Log.i(TAG, "disp=" + dw + "x" + dh + " desired before=" + beforeW + "x" + beforeH
                    + " after=" + afterW + "x" + afterH + " logo=" + lw + "x" + lh);

            // Full-bitmap crop; the stored wallpaper == screen size => 1:1, centered, static.
            if (Build.VERSION.SDK_INT >= 24) {
                wm.setBitmap(out, new Rect(0, 0, dw, dh), true,
                        WallpaperManager.FLAG_SYSTEM | WallpaperManager.FLAG_LOCK);
            } else {
                wm.setBitmap(out);
            }
            Log.i(TAG, "GCB wallpaper set OK (copied into wallpaper store)");
        } catch (Throwable t) {
            Log.e(TAG, "failed to set wallpaper", t);
        }
        finish();
    }
}
