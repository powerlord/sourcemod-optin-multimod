sourcemod-optin-multimod
========================

An opt-in Multi-Mod Plugin Manager

How does a plugin opt-in to using OIMM?

Participating plugins register 2-3 callbacks.

The mandatory callbacks are:

    functag public OptInMultiMod_StatusChanged(bool:enabled);

This function is called by the multimod manager whenever your plugin's status should change.
The enabled bool is set to true if your plugin is being activated and set to false if your
plugin is being disabled.

    functag public bool:OptInMultiMod_ValidateMap(const String:map[]);

This function is called to determine if your plugin supports a specific map.  This is useful
if your plugin only supports certain maps or certain map types.
For example of how this works, PropHunt Redux validates the map against its map configuration files,
while Huntsman Hell just validates that the map isn't MvM, PropHunt, or Vs. Saxton Hale.
Vs. Saxton Hale and Freak Fortress 2 would validate that the map is an arena_ or vsh_ map (more
specifically, they'd check it against their map prefix files.)

    functag public OptInMultiMod_GetTranslation(client, String:translation[], maxlength);
    
This function is optional.  It's used to translate the plugin name in the vote menu.  If you don't
implement this, it will just use the name your supplied when registering it.

So, how do you register a plugin?   In the plugin code (in OnAllPluginsLoaded), you call this function:

    native OptInMultiMod_Register(const String:name[], OptInMultiMod_ValidateMap:validateMap, OptInMultiMod_StatusChanged:status, OptInMultiMod_GetTranslation:translator=INVALID_FUNCTION);
    
The functions you pass are the same functions you defined with the earlier signatures.

There's one last function, but it's not strictly required:

    native OptInMultiMod_Unregister(const String:name[]);

This function will unregister your plugin from OIMM.  While this helps with some housecleaning, it isn't
strictly required as OIMM is smart enough to clean up after unloaded plugins before it selects the next
game mode.

So, why go through all this?  Simple!  This is the only game mode manager plugin that can switch modes
*every round* and not just when the map changes.
