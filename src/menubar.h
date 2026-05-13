typedef void (*MenuActionCallback)(const char *action, const char *params);
typedef void (*MenuActionResponse)(const char *route, const char *data);
void runMenuBarApp(MenuActionCallback callback, MenuActionResponse *response);
