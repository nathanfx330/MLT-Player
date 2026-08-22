// linux/runner/my_application.cc

#include "my_application.h"

#include <flutter_linux/flutter_linux.h>

#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"
#include "mlt_bridge.h"

/*
 * Everything Dart cannot reach on its own travels over this channel:
 * the id of the external video texture, the window's fullscreen state,
 * and paths dropped onto the window by the desktop.
 */
static constexpr char kHostChannel[] = "mlt_player/host";

struct _MyApplication {
  GtkApplication parent_instance;

  char** dart_entrypoint_arguments;

  GtkWindow* window;
  GtkWidget* header_bar;
  FlMethodChannel* host_channel;

  gboolean fullscreen;
};

G_DEFINE_TYPE(
    MyApplication,
    my_application,
    GTK_TYPE_APPLICATION
)

/* ------------------------------------------------------------------------- */
/* Texture registration                                                      */
/* ------------------------------------------------------------------------- */

static void register_mlt_texture(
    MyApplication* self,
    FlView* view
) {
  /*
   * Registration is idempotent, and first-frame can legitimately fire
   * more than once over the life of a view.
   */
  int64_t texture_id =
      mlt_bridge_texture_id();

  if (texture_id <= 0) {
    /*
     * By the time first-frame fires, the engine is rendering and its
     * texture registrar will accept external textures. Registering
     * during early startup is what used to produce a NULL registrar.
     */
    FlEngine* engine =
        fl_view_get_engine(view);

    if (engine == nullptr) {
      g_warning("MLT Player: Flutter engine is NULL.");
      return;
    }

    FlTextureRegistrar* texture_registrar =
        fl_engine_get_texture_registrar(engine);

    if (texture_registrar == nullptr) {
      g_warning("MLT Player: Flutter texture registrar is NULL.");
      return;
    }

    texture_id =
        mlt_bridge_register_flutter_texture(
            texture_registrar
        );

    if (texture_id <= 0) {
      g_warning(
          "MLT Player: failed to register the video texture."
      );

      return;
    }

    g_print(
        "MLT Flutter texture registered: %" G_GINT64_FORMAT "\n",
        texture_id
    );
  }

  /*
   * Tell Dart directly rather than making it poll. The Dart side also
   * asks once on startup, because these two events race.
   */
  if (self->host_channel != nullptr) {
    g_autoptr(FlValue) args =
        fl_value_new_int(texture_id);

    fl_method_channel_invoke_method(
        self->host_channel,
        "textureRegistered",
        args,
        nullptr,
        nullptr,
        nullptr
    );
  }
}

/* ------------------------------------------------------------------------- */
/* Window                                                                    */
/* ------------------------------------------------------------------------- */

static void apply_fullscreen(
    MyApplication* self,
    gboolean fullscreen
) {
  if (self->window == nullptr) {
    return;
  }

  self->fullscreen = fullscreen;

  /*
   * A client-side header bar stays on screen through a fullscreen
   * transition unless it is hidden explicitly, which rather defeats
   * the point.
   */
  if (self->header_bar != nullptr) {
    gtk_widget_set_visible(
        self->header_bar,
        !fullscreen
    );
  }

  if (fullscreen) {
    gtk_window_fullscreen(self->window);
  } else {
    gtk_window_unfullscreen(self->window);
  }
}

/* ------------------------------------------------------------------------- */
/* Host channel                                                              */
/* ------------------------------------------------------------------------- */

static void host_method_call_cb(
    FlMethodChannel* channel,
    FlMethodCall* method_call,
    gpointer user_data
) {
  (void)channel;

  MyApplication* self =
      MY_APPLICATION(user_data);

  const gchar* method =
      fl_method_call_get_name(method_call);

  g_autoptr(GError) error = nullptr;

  if (g_strcmp0(method, "getTextureId") == 0) {
    g_autoptr(FlValue) result =
        fl_value_new_int(
            mlt_bridge_texture_id()
        );

    fl_method_call_respond_success(
        method_call,
        result,
        &error
    );
  } else if (g_strcmp0(method, "setFullscreen") == 0) {
    FlValue* args =
        fl_method_call_get_args(method_call);

    const gboolean fullscreen =
        args != nullptr &&
        fl_value_get_type(args) == FL_VALUE_TYPE_BOOL &&
        fl_value_get_bool(args);

    apply_fullscreen(self, fullscreen);

    fl_method_call_respond_success(
        method_call,
        nullptr,
        &error
    );
  } else {
    g_autoptr(FlMethodResponse) response =
        FL_METHOD_RESPONSE(
            fl_method_not_implemented_response_new()
        );

    fl_method_call_respond(
        method_call,
        response,
        &error
    );
  }

  if (error != nullptr) {
    g_warning(
        "MLT Player: failed to respond to %s: %s",
        method,
        error->message
    );
  }
}

/* ------------------------------------------------------------------------- */
/* Drag and drop                                                             */
/* ------------------------------------------------------------------------- */

static void view_drag_data_received_cb(
    GtkWidget* widget,
    GdkDragContext* context,
    gint x,
    gint y,
    GtkSelectionData* selection_data,
    guint info,
    guint time,
    gpointer user_data
) {
  (void)widget;
  (void)context;
  (void)x;
  (void)y;
  (void)info;
  (void)time;

  MyApplication* self =
      MY_APPLICATION(user_data);

  if (self->host_channel == nullptr) {
    return;
  }

  g_auto(GStrv) uris =
      gtk_selection_data_get_uris(selection_data);

  if (uris == nullptr || uris[0] == nullptr) {
    return;
  }

  /*
   * Only the first path is used. A media player opening five files at
   * once has to invent a policy, and there is no playlist yet.
   */
  g_autoptr(GError) error = nullptr;

  g_autofree gchar* path =
      g_filename_from_uri(
          uris[0],
          nullptr,
          &error
      );

  if (path == nullptr) {
    g_warning(
        "MLT Player: dropped item is not a local file: %s",
        error != nullptr ? error->message : "unknown"
    );

    return;
  }

  g_autoptr(FlValue) args =
      fl_value_new_string(path);

  fl_method_channel_invoke_method(
      self->host_channel,
      "openPath",
      args,
      nullptr,
      nullptr,
      nullptr
  );
}

/* ------------------------------------------------------------------------- */
/* Startup                                                                   */
/* ------------------------------------------------------------------------- */

static void first_frame_cb(
    MyApplication* self,
    FlView* view
) {
  register_mlt_texture(self, view);

  /*
   * Reveal the window only once there is something to look at.
   */
  gtk_widget_show(
      gtk_widget_get_toplevel(
          GTK_WIDGET(view)
      )
  );
}

static void my_application_activate(
    GApplication* application
) {
  MyApplication* self =
      MY_APPLICATION(application);

  GtkWindow* window =
      GTK_WINDOW(
          gtk_application_window_new(
              GTK_APPLICATION(application)
          )
      );

  self->window = window;

  /*
   * Header bar under GNOME, traditional decorations elsewhere, since
   * other window managers handle client-side decoration inconsistently.
   */
  gboolean use_header_bar = TRUE;

#ifdef GDK_WINDOWING_X11
  GdkScreen* screen =
      gtk_window_get_screen(window);

  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name =
        gdk_x11_screen_get_window_manager_name(screen);

    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif

  if (use_header_bar) {
    GtkHeaderBar* header_bar =
        GTK_HEADER_BAR(gtk_header_bar_new());

    gtk_widget_show(GTK_WIDGET(header_bar));

    gtk_header_bar_set_title(header_bar, "MLT Player");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);

    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));

    self->header_bar = GTK_WIDGET(header_bar);
  } else {
    gtk_window_set_title(window, "MLT Player");

    self->header_bar = nullptr;
  }

  gtk_window_set_default_size(window, 1280, 720);

  g_autoptr(FlDartProject) project =
      fl_dart_project_new();

  fl_dart_project_set_dart_entrypoint_arguments(
      project,
      self->dart_entrypoint_arguments
  );

  FlView* view =
      fl_view_new(project);

  GdkRGBA background_color;

  gdk_rgba_parse(&background_color, "#000000");

  fl_view_set_background_color(view, &background_color);

  gtk_widget_show(GTK_WIDGET(view));

  gtk_container_add(
      GTK_CONTAINER(window),
      GTK_WIDGET(view)
  );

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  /*
   * The host channel has to exist before first-frame fires, because
   * that is when the texture id is pushed to Dart.
   */
  FlEngine* engine =
      fl_view_get_engine(view);

  if (engine != nullptr) {
    g_autoptr(FlStandardMethodCodec) codec =
        fl_standard_method_codec_new();

    self->host_channel =
        fl_method_channel_new(
            fl_engine_get_binary_messenger(engine),
            kHostChannel,
            FL_METHOD_CODEC(codec)
        );

    fl_method_channel_set_method_call_handler(
        self->host_channel,
        host_method_call_cb,
        self,
        nullptr
    );
  }

  /*
   * Accept media dropped from a file manager.
   */
  gtk_drag_dest_set(
      GTK_WIDGET(view),
      GTK_DEST_DEFAULT_ALL,
      nullptr,
      0,
      GDK_ACTION_COPY
  );

  gtk_drag_dest_add_uri_targets(GTK_WIDGET(view));

  g_signal_connect(
      view,
      "drag-data-received",
      G_CALLBACK(view_drag_data_received_cb),
      self
  );

  g_signal_connect_swapped(
      view,
      "first-frame",
      G_CALLBACK(first_frame_cb),
      self
  );

  gtk_widget_realize(GTK_WIDGET(view));
  gtk_widget_grab_focus(GTK_WIDGET(view));
}

static gboolean my_application_local_command_line(
    GApplication* application,
    gchar*** arguments,
    int* exit_status
) {
  MyApplication* self =
      MY_APPLICATION(application);

  self->dart_entrypoint_arguments =
      g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;

  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);

    *exit_status = 1;

    return TRUE;
  }

  g_application_activate(application);

  *exit_status = 0;

  return TRUE;
}

static void my_application_startup(
    GApplication* application
) {
  G_APPLICATION_CLASS(my_application_parent_class)
      ->startup(application);
}

static void my_application_shutdown(
    GApplication* application
) {
  MyApplication* self =
      MY_APPLICATION(application);

  /*
   * Detach the texture first so that nothing can be marked available
   * while the engine is being torn down, then stop MLT.
   */
  mlt_bridge_unregister_flutter_texture();
  mlt_bridge_shutdown();

  g_clear_object(&self->host_channel);

  G_APPLICATION_CLASS(my_application_parent_class)
      ->shutdown(application);
}

static void my_application_dispose(
    GObject* object
) {
  MyApplication* self =
      MY_APPLICATION(object);

  g_clear_pointer(
      &self->dart_entrypoint_arguments,
      g_strfreev
  );

  g_clear_object(&self->host_channel);

  G_OBJECT_CLASS(my_application_parent_class)
      ->dispose(object);
}

static void my_application_class_init(
    MyApplicationClass* klass
) {
  G_APPLICATION_CLASS(klass)->activate =
      my_application_activate;

  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;

  G_APPLICATION_CLASS(klass)->startup =
      my_application_startup;

  G_APPLICATION_CLASS(klass)->shutdown =
      my_application_shutdown;

  G_OBJECT_CLASS(klass)->dispose =
      my_application_dispose;
}

static void my_application_init(
    MyApplication* self
) {
  self->window = nullptr;
  self->header_bar = nullptr;
  self->host_channel = nullptr;
  self->fullscreen = FALSE;
}

MyApplication* my_application_new() {
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(
      g_object_new(
          my_application_get_type(),
          "application-id",
          APPLICATION_ID,
          "flags",
          G_APPLICATION_NON_UNIQUE,
          nullptr
      )
  );
}
