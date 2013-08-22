/**
 * vim: set ts=4 :
 * =============================================================================
 * Opt-in Multimod
 * Copyright (C) 2013 Ross Bemrose (Powerlord).  All rights reserved.
 * =============================================================================
 *
 * This program is free software; you can redistribute it and/or modify it under
 * the terms of the GNU General Public License, version 3.0, as published by the
 * Free Software Foundation.
 * 
 * This program is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more
 * details.
 *
 * You should have received a copy of the GNU General Public License along with
 * this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 * Version: $Id$
 */

#include <sourcemod>
#undef REQUIRE_PLUGIN
#include <nativevotes>
#include <umc-core>
#include <mapchooser_extended>
#include <mapchooser>

#pragma semicolon 1

#define VERSION "1.0.0"

new bool:g_bNativeVotes;
new bool:g_bMapChooser;

new bool:g_bEndOfMapVoteFinished = false;
new bool:g_bFirstRound;

new String:g_CurrentMode[64] = "\0";
new String:g_NextMode[64] = "\0";

new EngineVersion:g_EngineVersion;

new Handle:g_Cvar_Enabled;
new Handle:g_Cvar_Mode;
new Handle:g_Cvar_Frequency;
new Handle:g_Cvar_UseNativeVotes;
new Handle:g_Cvar_WaitingForPlayersTime;
new Handle:g_Cvar_BonusRoundTime;

new Handle:g_Kv_Plugins;

new bool:g_bLate;

new Handle:g_Array_CurrentPlugins;

enum
{
	MultiModMode_RandomMap = (1<<0), /**< Choose a random mode when the map starts.  If used with vote modes, only applies to first round */
	MultiModMode_RandomRound = (1<<1), /**< Choose a random mode each time the round starts */
	MultiModMode_VoteMap = (1<<2), /**< Vote for the mode at the start of each map.  */
	MultiModMode_VoteRound = (1<<3), /**< Vote for the mode after a round ends.  */
}

public Plugin:myinfo = 
{
	name = "Opt-in Multimod",
	author = "Powerlord",
	description = "Manages game modes",
	version = VERSION,
	url = "<- URL ->"
}

public APLRes:AskPluginLoad2(Handle:myself, bool:late, String:error[], err_max)
{
	g_EngineVersion = GetEngineVersion();
	g_bLate = late;
	
	CreateNative("OptInMultiMod_Register", Native_Register);
	
	RegPluginLibrary("optin_multimod");
	
	return APLRes_Success;
}

public OnPluginStart()
{
	CreateConVar("optin_multimod_version", VERSION, "Opt-in Multimod version", FCVAR_DONTRECORD|FCVAR_NOTIFY|FCVAR_PLUGIN);
	g_Cvar_Enabled = CreateConVar("optin_multimod_enabled", "1", "Enable Opt-in MultiMod?", FCVAR_DONTRECORD|FCVAR_NOTIFY|FCVAR_PLUGIN, true, 0.0, true, 1.0);
	g_Cvar_Mode = CreateConVar("optin_multimod_mode", "1", "Opt-in MultiMod operating mode. 0 = Random, 1 = Vote.", FCVAR_NOTIFY|FCVAR_PLUGIN, true, 0.0, true, 1.0);
	g_Cvar_Frequency = CreateConVar("optin_multimod_frequency", "1", "Opt-in MultiMod mode change timing. 0 = Per Map, 1 = Per Round.", FCVAR_NOTIFY|FCVAR_PLUGIN, true, 0.0, true, 1.0);
	g_Cvar_UseNativeVotes = CreateConVar("optin_multimod_nativevotes", "1", "Use NativeVotes for votes if available.  Only applies to TF2 (Valve broke it for CS:GO).", FCVAR_NOTIFY|FCVAR_PLUGIN, true, 0.0);

	HookEvent("round_start", Event_RoundStart, EventHookMode_Pre);
	HookEventEx("teamplay_round_start", Event_RoundStart, EventHookMode_Pre);
	HookEvent("round_end", Event_RoundEnd, EventHookMode_PostNoCopy);
	HookEventEx("teamplay_round_win", Event_RoundEnd, EventHookMode_PostNoCopy);
	
	g_Cvar_WaitingForPlayersTime = FindConVar("mp_waitingforplayers_time");
	if (g_Cvar_WaitingForPlayersTime == INVALID_HANDLE)
	{
		g_Cvar_WaitingForPlayersTime = FindConVar("mp_warmuptime");
	}
	
	g_Cvar_BonusRoundTime = FindConVar("mp_bonusroundtime");
	if (g_Cvar_BonusRoundTime == INVALID_HANDLE)
	{
		g_Cvar_BonusRoundTime = FindConVar("dod_bonusroundtime");
	}
	
	g_Kv_Plugins = CreateKeyValues("MultiMod");
	g_Array_CurrentPlugins = CreateArray(ByteCountToCells(64));
	AutoExecConfig(true, "optin_multimod.phrases");
	LoadTranslations("optin_multimod");
}

public OnConfigsExecuted()
{
	if (g_Cvar_BonusRoundTime != INVALID_HANDLE)
	{
		new time = GetConVarInt(g_Cvar_BonusRoundTime);
		new String:timeDefaultString[3];
		GetConVarDefault(g_Cvar_BonusRoundTime, timeDefaultString, sizeof(timeDefaultString));
		new timeDefault = StringToInt(timeDefaultString);
		if (timeDefault < time)
		{
			ResetConVar(g_Cvar_BonusRoundTime);
		}
	}
}

public OnAllPluginsLoaded()
{
	g_bMapChooser = LibraryExists("mapchooser");
	g_bNativeVotes = LibraryExists("nativevotes");
}

public OnLibraryAdded(const String:name[])
{
	if (StrEqual(name, "mapchooser", false))
	{
		g_bMapChooser = true;
	}
	else if (StrEqual(name, "nativevotes", false))
	{
		g_bNativeVotes = true;
	}
}

public OnLibraryRemoved(const String:name[])
{
	if (StrEqual(name, "mapchooser", false))
	{
		g_bMapChooser = false;
	}
	else if (StrEqual(name, "nativevotes", false))
	{
		g_bNativeVotes = false;
	}
}

public OnMapStart()
{
	g_bFirstRound = true;
	strcopy(g_CurrentMode, sizeof(g_CurrentMode), g_NextMode);
	g_NextMode = "\0";
	g_bEndOfMapVoteFinished = false;
	
	if (g_Array_CurrentPlugins != INVALID_HANDLE)
	{
		CloseHandle(g_Array_CurrentPlugins);
		g_Array_CurrentPlugins = INVALID_HANDLE;
	}
}

public OnMapEnd()
{
	if (g_Cvar_WaitingForPlayersTime != INVALID_HANDLE)
	{
		SetConVarInt(g_Cvar_WaitingForPlayersTime, 60);
	}
}

Handle:CheckMap(const String:map[])
{
	KvRewind(g_Kv_Plugins);
	
	if (!KvGotoFirstSubKey(g_Kv_Plugins))
	{
		return INVALID_HANDLE;
	}

	new Handle:array_PluginNames = CreateArray(ByteCountToCells(64));
	
	do
	{
		new Handle:validateMap = Handle:KvGetNum(g_Kv_Plugins, "validateMap", _:INVALID_HANDLE);
		
		if (validateMap == INVALID_HANDLE || GetForwardFunctionCount(validateMap) == 0)
		{
			continue;
		}
		
		new bool:result = false;
		
		Call_StartForward(validateMap);
		Call_PushString(map);
		Call_Finish(result);
		
		if (result)
		{
			new String:name[64];
			KvGetSectionName(g_Kv_Plugins, name, sizeof(name));
			
			PushArrayString(g_Array_CurrentPlugins, name);
		}
		
	} while (KvGotoNextKey(g_Kv_Plugins));
	
	return array_PluginNames;
}

// This is a pre-hook just so that we get called before any other plugins do.
public Action:Event_RoundStart(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (!GetConVarBool(g_Cvar_Enabled))
	{
		return Plugin_Continue;
	}
	
	if (g_bFirstRound)
	{
	}
	
	if (GetConVarInt(g_Cvar_Mode) & MultiModMode_RandomRound)
	{
	}
	g_bFirstRound = false;

	if (!g_bEndOfMapVoteFinished && g_bMapChooser && EndOfMapVoteEnabled() && HasEndOfMapVoteFinished())
	{
		new String:map[PLATFORM_MAX_PATH];
		GetNextMap(map, PLATFORM_MAX_PATH);
		
		SharedMapLogic(map);
		//TODO Do something with the next map
	}
	
	return Plugin_Continue;
}

// nocopy because we don't care who wins
public Event_RoundEnd(Handle:event, const String:name[], bool:dontBroadcast)
{
}

public UMC_OnNextmapSet(Handle:kv, const String:map[], const String:group[], const String:display[])
{
	SharedMapLogic(map);
	g_bEndOfMapVoteFinished = true;
}

public OnMapVoteEnd(const String:map[])
{
	SharedMapLogic(map);
	g_bEndOfMapVoteFinished = true;
}

SharedMapLogic(const String:map[])
{
	new modes = GetConVarInt(g_Cvar_Mode);
	if (modes & MultiModMode_VoteMap || modes & MultiModMode_VoteRound)
	{
		new Handle:validPlugins = CheckMap(map);
		
		if (GetArraySize(validPlugins) == 0)
		{
			return;
		}
		
		PrepareVote(validPlugins, 15);
	}
}

PrepareVote(Handle:validPlugins, time, bool:nextMap = false)
{
	new size = GetArraySize(validPlugins);
	new bool:useNativeVotes = g_bNativeVotes && GetConVarBool(g_Cvar_UseNativeVotes) && NativeVotes_IsVoteTypeSupported(NativeVotesType_Custom_Mult) &&
		size <= NativeVotes_GetMaxItems();
	
	new Handle:vote;
	
	new Function:voteHandler;
	new String:voteTitle[128];
	
	if (nextMap)
	{
		voteHandler = VoteHandlerNextMap;
		Format(voteTitle, sizeof(voteTitle), "%T", "Vote Mode NextMap", LANG_SERVER);
	}
	else
	{
		voteHandler = VoteHandlerNextRound;
		Format(voteTitle, sizeof(voteTitle), "%T", "Vote Mode NextRound", LANG_SERVER);
	}
	
	if (useNativeVotes)
	{
		vote = NativeVotes_Create(voteHandler, NativeVotesType_Custom_Mult);
		NativeVotes_SetDetails(vote, voteTitle);
	}
	else
	{
		vote = CreateMenu(voteHandler, MENU_ACTIONS_DEFAULT|MenuAction_Display|MenuAction_VoteEnd);
		SetMenuTitle(vote, "%s", voteTitle);
	}
	
	for (new i = 0; i < size; ++i)
	{
		new String:pluginName[64];
		GetArrayString(validPlugins, i, pluginName, sizeof(pluginName));
		
		if (useNativeVotes)
		{
			NativeVotes_AddItem(vote, pluginName, pluginName);
		}
		else
		{
			AddMenuItem(vote, pluginName, pluginName);
		}
	}
	
	if (useNativeVotes)
	{
		NativeVotes_DisplayToAll(vote, time);
	}
	else
	{
		VoteMenuToAll(vote, time);
	}
}

public VoteHandlerNextMap(Handle:menu, MenuAction:action, param1, param2)
{
	new bool:useNativeVotes = g_bNativeVotes && GetConVarBool(g_Cvar_UseNativeVotes);

	switch (action)
	{
		// Only call this for non-NativeVotes
		case MenuAction_Display:
		{
			new String:voteTitle[128];
			Format(voteTitle, sizeof(voteTitle), "%T", "Vote Mode NextMap", param1);
			SetPanelTitle(Handle:param2, voteTitle);
		}
		
		case MenuAction_End:
		{
			CloseHandle(menu);
		}
		
		case MenuAction_VoteCancel:
		{
			
		}
		
		case MenuAction_VoteEnd:
		{
			new String:winner[64];
			if (useNativeVotes)
			{
				NativeVotes_GetItem(menu, param1, winner, sizeof(winner));
				
			}
			else
			{
				GetMenuItem(menu, param1, winner, sizeof(winner));
			}
			
			
			
			PrintHintTextToAll("%t", "Vote Win", winner);
		}
	}
}

public VoteHandlerNextRound(Handle:menu, MenuAction:action, param1, param2)
{
	new bool:useNativeVotes = g_bNativeVotes && GetConVarBool(g_Cvar_UseNativeVotes);

	switch (action)
	{
		// Only call this for non-NativeVotes
		case MenuAction_Display:
		{
			new String:voteTitle[128];
			Format(voteTitle, sizeof(voteTitle), "%T", "Vote Mode NextRound", param1);
			SetPanelTitle(Handle:param2, voteTitle);
		}
		
		case MenuAction_End:
		{
			CloseHandle(menu);
		}
	}
}

// native OptInMultiMod_Register(const String:name[], OptInMultiMod_ValidateMap:validateMap, OptInMultiMod_StatusChanged:status);
public Native_Register(Handle:plugin, args)
{
	new size;
	GetNativeStringLength(1, size);
	
	if (size <= 0)
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Invalid Plugin Name.");
		return;
	}
	
	new String:name[size];
	GetNativeString(1, name, size);
	
	KvRewind(g_Kv_Plugins);
	
	new Function:validateMap = GetNativeCell(2);
	
	if (validateMap == INVALID_FUNCTION)
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Invalid OptInMultiMod_ValidateMap Function.");
		return;
	}
	
	new Function:statusChanged = GetNativeCell(3);

	if (statusChanged == INVALID_FUNCTION)
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Invalid OptInMultiMod_StatusChanged Function.");
		return;
	}
	
	AddPlugin(plugin, name, validateMap, statusChanged);
}

AddPlugin(Handle:plugin, const String:name[], Function:validateMap, Function:statusChanged)
{
	new Handle:validateForward = INVALID_HANDLE;
	new Handle:statusForward = INVALID_HANDLE;
	
	KvJumpToKey(g_Kv_Plugins, name, true); // Find or create this key

	validateForward = Handle:KvGetNum(g_Kv_Plugins, "validateMap", _:INVALID_HANDLE);
	statusForward = Handle:KvGetNum(g_Kv_Plugins, "statusChanged", _:INVALID_HANDLE);

	if (validateForward != INVALID_HANDLE && statusForward == INVALID_HANDLE)
	{
		// Validate forward is in a bad state, clean it up
		LogMessage("Cleaning up stale validateMap forward");
		CloseHandle(validateForward);
		validateForward = INVALID_HANDLE;
	}
	else if (validateForward == INVALID_HANDLE && statusForward != INVALID_HANDLE)
	{
		// Status forward is in a bad state, clean it up
		LogMessage("Cleaning up stale statusChanged forward");
		CloseHandle(statusForward);
		statusForward = INVALID_HANDLE;
	}
	else if (validateForward != INVALID_HANDLE && validateForward != INVALID_HANDLE)
	{
		if (GetForwardFunctionCount(validateForward) > 0 && GetForwardFunctionCount(statusForward) > 0)
		{
			KvRewind(g_Kv_Plugins);
			ThrowNativeError(SP_ERROR_NATIVE, "A plugin named \"%s\" is already registered", name);
			return;
		}
		else if (GetForwardFunctionCount(validateForward) > 0 && GetForwardFunctionCount(statusForward) == 0)
		{
			// Whoops, more issues
			LogMessage("Cleaning up orphaned validateMap function");
			CloseHandle(validateForward);
			validateForward = INVALID_HANDLE;
		}
		else if (GetForwardFunctionCount(validateForward) == 0 && GetForwardFunctionCount(statusForward) > 0)
		{
			// Whoops, more issues
			LogMessage("Cleaning up orphaned statusChanged function");
			CloseHandle(statusForward);
			statusForward = INVALID_HANDLE;
		}
	}
	
	if (validateForward == INVALID_HANDLE)
	{
		validateForward = CreateForward(ET_Single, Param_String);
		KvSetNum(g_Kv_Plugins, "validateMap", _:validateForward);
	}
	
	if (statusForward == INVALID_HANDLE)
	{
		statusForward = CreateForward(ET_Ignore, Param_Cell);
		KvSetNum(g_Kv_Plugins, "statusChanged", _:statusForward);
	}
	
	AddToForward(validateForward, plugin, validateMap);
	AddToForward(statusForward, plugin, statusChanged);
}

RemovePlugin(const String:name[])
{
	KvRewind(g_Kv_Plugins);
	if (KvJumpToKey(g_Kv_Plugins, name))
	{
		new Handle:validateForward = KvGetNum(g_Kv_Plugins, "validateMap", INVALID_HANDLE);
		if (validateForward != INVALID_HANDLE)
		{
			CloseHandle(validateForward);
		}
		
		new Handle:statusChanged = KvGetNum(g_Kv_Plugins, "statusChanged", INVALID_HANDLE);
		if (statusChanged != INVALID_HANDLE)
		{
			CloseHandle(statusChanged);
		}
		
		KvDeleteThis(g_Kv_Plugins);
		KvRewind(g_Kv_Plugins);
	}
}
