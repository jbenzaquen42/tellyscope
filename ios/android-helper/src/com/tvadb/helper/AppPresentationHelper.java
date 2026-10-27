package com.tvadb.helper;

import android.app.Application;
import android.app.Instrumentation;
import android.content.Context;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.drawable.Drawable;
import android.os.Build;
import android.os.Looper;
import android.util.Base64;

import java.io.ByteArrayOutputStream;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;

/**
 * A tiny, install-free app_process helper used by TVADB.
 *
 * The iOS client pushes the compiled DEX to /data/local/tmp, executes it as the
 * ADB shell user, reads the tab-separated/base64 response, and removes it when
 * the session ends. Individual package failures do not abort the whole batch.
 */
public final class AppPresentationHelper {
    private static final String HEADER = "TVADB_ICON_HELPER_V1";
    private static final int ICON_SIZE = 96;
    private static final int BASE64_FLAGS = Base64.NO_WRAP;

    private AppPresentationHelper() {
    }

    public static void main(String[] packageNames) {
        try {
            if (Looper.myLooper() == null) {
                Looper.prepareMainLooper();
            }
            Context context = createSystemContext();
            PackageManager packageManager = context.getPackageManager();
            if (packageManager == null) {
                throw new IllegalStateException("PackageManager unavailable");
            }

            System.out.println(HEADER);
            for (String packageName : packageNames) {
                writePresentation(packageManager, packageName);
            }
            System.out.flush();
        } catch (Throwable error) {
            Throwable root = rootCause(error);
            System.out.println(
                HEADER
                    + "_ERROR\t"
                    + encode(root.getClass().getSimpleName())
                    + "\t"
                    + encode(root.getMessage() == null ? "" : root.getMessage())
            );
            System.out.flush();
        } finally {
            // ActivityThread and PackageManager may start Binder/Looper threads
            // that keep vendor app_process builds alive after main() returns.
            // The helper is a one-shot command, so terminate explicitly once
            // the complete response has been flushed.
            System.exit(0);
        }
    }

    private static void writePresentation(PackageManager packageManager, String packageName) {
        String stage = "application-info";
        try {
            ApplicationInfo applicationInfo = packageManager.getApplicationInfo(packageName, 0);
            stage = "package-info";
            PackageInfo packageInfo = packageManager.getPackageInfo(packageName, 0);
            stage = "label";
            CharSequence label = packageManager.getApplicationLabel(applicationInfo);
            stage = "icon";
            Drawable icon = packageManager.getApplicationIcon(applicationInfo);

            String name = label == null ? packageName : label.toString();
            String versionName = packageInfo.versionName == null ? "" : packageInfo.versionName;
            stage = "render";
            byte[] iconData = renderIcon(icon);

            System.out.println(
                "A\t"
                    + encode(packageName) + "\t"
                    + encode(name) + "\t"
                    + encode(versionName) + "\t"
                    + Base64.encodeToString(iconData, BASE64_FLAGS)
            );
        } catch (Throwable error) {
            Throwable root = rootCause(error);
            System.out.println(
                "E\t"
                    + encode(packageName) + "\t"
                    + encode(root.getClass().getSimpleName()) + "\t"
                    + encode(stage + ": " + (root.getMessage() == null ? "" : root.getMessage()))
            );
        }
    }

    private static byte[] renderIcon(Drawable drawable) {
        if (drawable == null) {
            return new byte[0];
        }
        Bitmap bitmap = Bitmap.createBitmap(ICON_SIZE, ICON_SIZE, Bitmap.Config.ARGB_8888);
        Canvas canvas = new Canvas(bitmap);
        drawable.setBounds(0, 0, ICON_SIZE, ICON_SIZE);
        drawable.draw(canvas);

        ByteArrayOutputStream output = new ByteArrayOutputStream(16 * 1024);
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, output);
        bitmap.recycle();
        return output.toByteArray();
    }

    private static String encode(String value) {
        return Base64.encodeToString(value.getBytes(StandardCharsets.UTF_8), BASE64_FLAGS);
    }

    /**
     * app_process does not start a normal Android application. Populate the
     * minimum ActivityThread state required for ContextImpl to load resources.
     * This follows the same install-free server pattern used by scrcpy.
     */
    static Context createSystemContext() throws Exception {
        Class<?> activityThreadClass = Class.forName("android.app.ActivityThread");
        Constructor<?> constructor = activityThreadClass.getDeclaredConstructor();
        constructor.setAccessible(true);
        Object activityThread = constructor.newInstance();

        setStaticField(activityThreadClass, "sCurrentActivityThread", activityThread);
        setBooleanField(activityThreadClass, activityThread, "mSystemThread", true);

        if (Build.VERSION.SDK_INT >= 31) {
            fillConfigurationController(activityThreadClass, activityThread);
        }
        fillAppInfo(activityThreadClass, activityThread);

        Method getSystemContext = activityThreadClass.getDeclaredMethod("getSystemContext");
        getSystemContext.setAccessible(true);
        Context context = (Context) getSystemContext.invoke(activityThread);
        if (context == null) {
            throw new IllegalStateException("System context unavailable");
        }
        fillInitialApplication(activityThreadClass, activityThread, context);
        return context;
    }

    private static void fillAppInfo(
        Class<?> activityThreadClass,
        Object activityThread
    ) {
        try {
            Class<?> appBindDataClass = Class.forName("android.app.ActivityThread$AppBindData");
            Constructor<?> constructor = appBindDataClass.getDeclaredConstructor();
            constructor.setAccessible(true);
            Object appBindData = constructor.newInstance();

            ApplicationInfo applicationInfo = new ApplicationInfo();
            applicationInfo.packageName = "com.android.shell";

            Field appInfoField = appBindDataClass.getDeclaredField("appInfo");
            appInfoField.setAccessible(true);
            appInfoField.set(appBindData, applicationInfo);

            Field boundApplicationField = activityThreadClass.getDeclaredField("mBoundApplication");
            boundApplicationField.setAccessible(true);
            boundApplicationField.set(activityThread, appBindData);
        } catch (Throwable ignored) {
            // This is a compatibility workaround. Some old/vendor frameworks
            // do not expose AppBindData, while their PackageManager path works
            // without it.
        }
    }

    private static void fillInitialApplication(
        Class<?> activityThreadClass,
        Object activityThread,
        Context context
    ) {
        try {
            Application application = Instrumentation.newApplication(
                Application.class,
                context
            );
            Field field = activityThreadClass.getDeclaredField("mInitialApplication");
            field.setAccessible(true);
            field.set(activityThread, application);
        } catch (Throwable ignored) {
            // Resource lookup on most devices only needs the system context.
            // Keep going when a vendor Application implementation refuses to
            // attach to it.
        }
    }

    private static void setStaticField(Class<?> owner, String name, Object value) throws Exception {
        Field field = owner.getDeclaredField(name);
        field.setAccessible(true);
        field.set(null, value);
    }

    private static void setBooleanField(
        Class<?> owner,
        Object target,
        String name,
        boolean value
    ) throws Exception {
        Field field = owner.getDeclaredField(name);
        field.setAccessible(true);
        field.setBoolean(target, value);
    }

    private static void fillConfigurationController(
        Class<?> activityThreadClass,
        Object activityThread
    ) {
        try {
            Class<?> controllerClass = Class.forName("android.app.ConfigurationController");
            Class<?> internalClass = Class.forName("android.app.ActivityThreadInternal");
            Constructor<?> constructor = controllerClass.getDeclaredConstructor(internalClass);
            constructor.setAccessible(true);
            Object controller = constructor.newInstance(activityThread);

            Field field = activityThreadClass.getDeclaredField("mConfigurationController");
            field.setAccessible(true);
            field.set(activityThread, controller);
        } catch (Throwable ignored) {
            // Vendor frameworks vary. Context creation still works without this
            // workaround on most devices, so let the normal path continue.
        }
    }

    private static Throwable rootCause(Throwable error) {
        Throwable current = error;
        for (int depth = 0; depth < 8; depth++) {
            Throwable cause;
            if (current instanceof InvocationTargetException) {
                cause = ((InvocationTargetException) current).getTargetException();
            } else {
                cause = current.getCause();
            }
            if (cause == null || cause == current) {
                break;
            }
            current = cause;
        }
        return current;
    }

}
