package com.tvadb.helper;

import android.content.Context;
import android.hardware.input.InputManager;
import android.os.Build;
import android.os.Looper;
import android.view.Display;

import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;

/**
 * Associates the `phys` port of TVADB's UHID mouse with an Android display.
 *
 * Android 15 routes independent mouse cursors per display. A UHID device with
 * no port association may still be recognized as a mouse while its cursor is
 * assigned to display -1. This one-shot app_process helper calls the framework
 * API as the already-authorized ADB shell user.
 */
public final class MouseDisplayAssociation {
    private static final String READY = "TVADB_MOUSE_ASSOCIATION_READY";
    private static final String REMOVED = "TVADB_MOUSE_ASSOCIATION_REMOVED";
    private static final String UNSUPPORTED = "TVADB_MOUSE_ASSOCIATION_UNSUPPORTED";

    private MouseDisplayAssociation() {
    }

    public static void main(String[] arguments) {
        try {
            if (Build.VERSION.SDK_INT < 35) {
                System.out.println(UNSUPPORTED);
                return;
            }
            if (arguments.length < 2) {
                throw new IllegalArgumentException("Expected add/remove and input port");
            }
            if (Looper.myLooper() == null) {
                Looper.prepareMainLooper();
            }

            Context context = AppPresentationHelper.createSystemContext();
            InputManager inputManager =
                (InputManager) context.getSystemService(Context.INPUT_SERVICE);
            if (inputManager == null) {
                throw new IllegalStateException("InputManager unavailable");
            }

            String operation = arguments[0];
            String inputPort = arguments[1];
            if ("add".equals(operation)) {
                int displayId = arguments.length >= 3
                    ? Integer.parseInt(arguments[2])
                    : Display.DEFAULT_DISPLAY;
                String displayUniqueId = displayUniqueId(context, displayId);
                invoke(
                    inputManager,
                    "addUniqueIdAssociationByPort",
                    new Class<?>[] {String.class, String.class},
                    inputPort,
                    displayUniqueId
                );
                System.out.println(READY + "\t" + displayUniqueId);
            } else if ("remove".equals(operation)) {
                invoke(
                    inputManager,
                    "removeUniqueIdAssociationByPort",
                    new Class<?>[] {String.class},
                    inputPort
                );
                System.out.println(REMOVED);
            } else {
                throw new IllegalArgumentException("Unknown operation: " + operation);
            }
        } catch (Throwable error) {
            Throwable root = rootCause(error);
            System.out.println(
                "TVADB_MOUSE_ASSOCIATION_ERROR\t"
                    + root.getClass().getSimpleName()
                    + "\t"
                    + (root.getMessage() == null ? "" : root.getMessage())
            );
        } finally {
            System.out.flush();
            System.exit(0);
        }
    }

    private static String displayUniqueId(Context context, int displayId)
        throws Exception {
        Object displayManager = context.getSystemService("display");
        if (displayManager == null) {
            throw new IllegalStateException("DisplayManager unavailable");
        }
        Method getDisplay = displayManager
            .getClass()
            .getMethod("getDisplay", int.class);
        Display display = (Display) getDisplay.invoke(displayManager, displayId);
        if (display == null) {
            throw new IllegalStateException("Display unavailable: " + displayId);
        }
        Method method = Display.class.getDeclaredMethod("getUniqueId");
        method.setAccessible(true);
        String uniqueId = (String) method.invoke(display);
        if (uniqueId == null || uniqueId.isEmpty()) {
            throw new IllegalStateException("Display unique id unavailable");
        }
        return uniqueId;
    }

    private static void invoke(
        InputManager inputManager,
        String name,
        Class<?>[] parameterTypes,
        Object... arguments
    ) throws Exception {
        Method method = InputManager.class.getMethod(name, parameterTypes);
        method.invoke(inputManager, arguments);
    }

    private static Throwable rootCause(Throwable error) {
        Throwable current = error;
        for (int depth = 0; depth < 8; depth++) {
            Throwable cause = current instanceof InvocationTargetException
                ? ((InvocationTargetException) current).getTargetException()
                : current.getCause();
            if (cause == null || cause == current) {
                break;
            }
            current = cause;
        }
        return current;
    }
}
