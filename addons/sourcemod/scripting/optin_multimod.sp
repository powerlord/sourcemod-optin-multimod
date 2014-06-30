/**
 * vim: set ts=4 :
 * =============================================================================
 * Opt-in Multimod
 * A Multi-mod plugin that uses explicit support from the game to do voting
 * for game modes.  Can do votes per-round.
 * 
 * Copyright (C) 2013-2014 Ross Bemrose (Powerlord).  All rights reserved.
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
#include <sdktools>
#undef REQUIRE_PLUGIN
#include <nativevotes>

#pragma semicolon 1

#define VERSION "1.0.0 alpha"

#define STATUS_FORWARD "statusChanged"
#define VALIDATE_FORWARD "validateMap"
#define TRANSLATE_FORWARD "translateName"

#define STANDARD "standard"
#define MEDIEVAL "medieval"

#define CONFIGS "configs/oimm/"

enum RoundCounting
{
	RoundCounting_Standard = 0,
	RoundCounting_MvM,
	RoundCounting_ArmsRace,
}

new RoundCounting:g_RoundCounting = RoundCounting_Standard;

// These correspond to tf_gamerules m_nGameType netprop
enum
{
	TF2_GameType_Unknown	= 0,
	TF2_GameType_CTF		= 1,
	TF2_GameType_CP			= 2,
	TF2_GameType_PL			= 3,
	TF2_GameType_Arena		= 4,
}

// CSGO requires two cvars to get the game type
enum
{
	CSGO_GameType_Classic	= 0,
	CSGO_GameType_GunGame	= 1,
	CSGO_GameType_Training	= 2,
	CSGO_GameType_Custom	= 3,
}

enum
{
	CSGO_GunGameMode_ArmsRace	= 0,
	CSGO_GunGameMode_Demolition	= 1,
	CSGO_GunGameMode_DeathMatch	= 2,
}

new bool:g_bNativeVotes;

new String:g_CurrentMode[128] = STANDARD;
new String:g_NextMode[128];
new String:g_NextMapMode[128];

new EngineVersion:g_EngineVersion;

new Handle:g_Cvar_Enabled;
new Handle:g_Cvar_Mode;
new Handle:g_Cvar_Frequency;
new Handle:g_Cvar_UseNativeVotes;
new Handle:g_Cvar_MedievalAvailable;
new Handle:g_Cvar_StandardAvailable;

// Valve Cvars
new Handle:g_Cvar_Bonusroundtime;
new Handle:g_Cvar_Medieval;
new Handle:g_Cvar_Maxrounds;
new Handle:g_Cvar_Winlimit;
new Handle:g_Cvar_MatchClinch;
new Handle:g_Cvar_GameType;
new Handle:g_Cvar_GameMode;

new bool:g_bNextMapMedieval;

new Handle:g_Kv_Plugins;

new Handle:g_Array_CurrentPlugins;

new Handle:g_hMapPrefixes;

new Handle:g_hRetryTimer = INVALID_HANDLE;
new bool:g_bMapEnded = false;
new bool:g_HasIntermissionStarted = false;
new g_ObjectiveEnt = -1;

// Various score counters and such to track when the last round will happen
/* Upper bound of how many team there could be */
#define MAXTEAMS 10
new g_winCount[MAXTEAMS];
new g_TotalRounds = 0;

enum
{
	Mode_Random,
	Mode_Vote,
}

enum
{
	Frequency_Map,
	Frequency_Round,
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
	
	CreateNative("OptInMultiMod_Register", Native_Register);
	CreateNative("OptInMultiMod_Unregister", Native_Unregister);
	
	RegPluginLibrary("optin_multimod");
	
	return APLRes_Success;
}

public OnPluginStart()
{
	CreateConVar("optin_multimod_version", VERSION, "Opt-in Multimod version", FCVAR_DONTRECORD|FCVAR_NOTIFY|FCVAR_PLUGIN);
	g_Cvar_Enabled = CreateConVar("optin_multimod_enabled", "1", "Enable Opt-in MultiMod?", FCVAR_DONTRECORD|FCVAR_NOTIFY|FCVAR_PLUGIN, true, 0.0, true, 1.0);
	g_Cvar_Mode = CreateConVar("optin_multimod_mode", "1", "Opt-in MultiMod operating mode. 0 = Random, 1 = Vote.", FCVAR_PLUGIN, true, 0.0, true, 1.0);
	g_Cvar_Frequency = CreateConVar("optin_multimod_frequency", "1", "Opt-in MultiMod mode change timing. 0 = Per Map, 1 = Per Round.", FCVAR_PLUGIN, true, 0.0, true, 1.0);
	g_Cvar_UseNativeVotes = CreateConVar("optin_multimod_nativevotes", "1", "Use NativeVotes for votes if available.  Only applies to TF2 (Valve broke it for CS:GO).", FCVAR_PLUGIN, true, 0.0);
	g_Cvar_StandardAvailable = CreateConVar("optin_multimod_standard", "1", "Allow standard gameplay on recognized map prefixes?", FCVAR_PLUGIN, true, 0.0, true, 1.0);
	g_Cvar_MedievalAvailable = CreateConVar("optin_multimod_medieval", "0", "TF2 only: Add Medieval to modes list?", FCVAR_PLUGIN, true, 0.0, true, 1.0);

	HookEvent("round_start", Event_RoundStart, EventHookMode_Pre);
	HookEvent("round_end", Event_RoundEnd, EventHookMode_PostNoCopy);
	
	HookConVarChange(FindConVar("sm_nextmap"), CvarNextMap);
	
	g_Cvar_Maxrounds = FindConVar("mp_maxrounds");
	g_Cvar_Winlimit = FindConVar("mp_winlimit");
	
	
	RegConsoleCmd("currentmode", Cmd_CurrentMode, "Show current mode");

	g_hMapPrefixes = CreateArray(ByteCountToCells(10));
	
	// For map prefixes
	switch (g_EngineVersion)
	{
		case Engine_CSS:
		{
			PushArrayString(g_hMapPrefixes, "as");
			PushArrayString(g_hMapPrefixes, "cs");
			PushArrayString(g_hMapPrefixes, "de");
			
			g_Cvar_Bonusroundtime = FindConVar("mp_round_restart_delay");
			
			HookEvent("round_start", Event_RoundStart, EventHookMode_Pre);
			HookEvent("round_end", Event_RoundEnd);
		}
		
		case Engine_CSGO:
		{
			PushArrayString(g_hMapPrefixes, "ar");
			PushArrayString(g_hMapPrefixes, "cs");
			PushArrayString(g_hMapPrefixes, "de");
			
			g_Cvar_Bonusroundtime = FindConVar("mp_round_restart_delay");
			g_Cvar_MatchClinch = FindConVar("mp_match_can_clinch");
			g_Cvar_GameType = FindConVar("game_type");
			g_Cvar_GameMode = FindConVar("game_mode");
			
			HookEvent("cs_intermission", Event_Intermission);
			HookEvent("announce_phase_end", Event_PhaseEnd);
			HookEvent("round_start", Event_RoundStart, EventHookMode_Pre);
			HookEvent("round_end", Event_RoundEnd);
		}
		
		case Engine_DODS:
		{
			PushArrayString(g_hMapPrefixes, "dod");
			
			g_Cvar_Bonusroundtime = FindConVar("dod_bonusroundtime");
			
			HookEvent("dod_round_start ", Event_RoundStart, EventHookMode_Pre);
			HookEvent("dod_round_win", Event_RoundEnd);
		}
		
		case Engine_HL2DM:
		{
			PushArrayString(g_hMapPrefixes, "dm");
			
			g_Cvar_Bonusroundtime = FindConVar("mp_bonusroundtime");
			
			HookEvent("round_start", Event_RoundStart, EventHookMode_Pre);
			HookEvent("teamplay_round_start", Event_RoundStart, EventHookMode_Pre);
			HookEvent("round_end", Event_RoundEnd);
		}
		
		case Engine_NuclearDawn:
		{
			PushArrayString(g_hMapPrefixes, "nd");
			
			g_Cvar_Bonusroundtime = FindConVar("mp_bonusroundtime");
			
			HookEvent("round_start", Event_RoundStart, EventHookMode_Pre);
			HookEvent("round_win", Event_RoundEnd);
		}
		
		case Engine_TF2:
		{
			PushArrayString(g_hMapPrefixes, "tc");
			PushArrayString(g_hMapPrefixes, "cp");
			PushArrayString(g_hMapPrefixes, "ctf");
			PushArrayString(g_hMapPrefixes, "pl");
			PushArrayString(g_hMapPrefixes, "arena");
			PushArrayString(g_hMapPrefixes, "plr");
			PushArrayString(g_hMapPrefixes, "koth");
			PushArrayString(g_hMapPrefixes, "sd");
			PushArrayString(g_hMapPrefixes, "mvm");
			
			g_Cvar_Medieval = FindConVar("tf_medieval");
			g_Cvar_Bonusroundtime = FindConVar("mp_bonusroundtime");
			
			HookEvent("teamplay_round_start", Event_RoundStart, EventHookMode_Pre);
			HookEvent("teamplay_round_win", Event_RoundEnd);
			HookEvent("teamplay_win_panel", Event_TeamPlayWinPanel);
			HookEvent("teamplay_restart_round", Event_TFRestartRound);
			HookEvent("arena_win_panel", Event_TeamPlayWinPanel);
			HookEvent("pve_win_panel", Event_MvMWinPanel);
			
		}
		
		default:
		{
			g_Cvar_Bonusroundtime = FindConVar("mp_bonusroundtime");
			
			HookEvent("round_start", Event_RoundStart, EventHookMode_Pre);
			HookEvent("round_end", Event_RoundEnd);
		}
	}
	
	g_Kv_Plugins = CreateKeyValues("MultiMod");
	//g_Array_CurrentPlugins = CreateArray(ByteCountToCells(64));
	AutoExecConfig(true, "optin_multimod");
	LoadTranslations("optin_multimod.phrases");
}

public OnConfigsExecuted()
{
	g_TotalRounds = 0;
	
	for (new i = 0; i < MAXTEAMS; i++)
	{
		g_winCount[i] = 0;	
	}
	
	if (g_Cvar_Bonusroundtime != INVALID_HANDLE)
	{
		new time = GetConVarInt(g_Cvar_Bonusroundtime);
		new String:timeDefaultString[3];
		GetConVarDefault(g_Cvar_Bonusroundtime, timeDefaultString, sizeof(timeDefaultString));
		new timeDefault = StringToInt(timeDefaultString);
		if (timeDefault < time)
		{
			ResetConVar(g_Cvar_Bonusroundtime);
		}
	}
}

public OnAllPluginsLoaded()
{
	g_bNativeVotes = LibraryExists("nativevotes") && NativeVotes_IsVoteTypeSupported(NativeVotesType_Custom_Mult);
}

public OnLibraryAdded(const String:name[])
{
	if (StrEqual(name, "nativevotes", false) && NativeVotes_IsVoteTypeSupported(NativeVotesType_Custom_Mult))
	{
		g_bNativeVotes = true;
	}
}

public OnLibraryRemoved(const String:name[])
{
	if (StrEqual(name, "nativevotes", false))
	{
		g_bNativeVotes = false;
	}
}

public OnMapStart()
{
	g_CurrentMode = STANDARD;
	if (g_EngineVersion == Engine_TF2 && GameRules_GetProp("m_bPlayingMannVsMachine"))
	{
		g_RoundCounting = RoundCounting_MvM;
		g_ObjectiveEnt = EntIndexToEntRef(FindEntityByClassname(-1, "tf_objective_resource"));
	}
	else if (g_EngineVersion == Engine_CSGO && GetConVarInt(g_Cvar_GameType) == CSGO_GameType_GunGame &&
	GetConVarInt(g_Cvar_GameMode) == CSGO_GunGameMode_ArmsRace)
	{
		g_RoundCounting = RoundCounting_ArmsRace;
	}

	g_bMapEnded = false;
	g_bNextMapMedieval = false;
	
	if (g_Array_CurrentPlugins != INVALID_HANDLE)
	{
		CloseHandle(g_Array_CurrentPlugins);
		g_Array_CurrentPlugins = INVALID_HANDLE;
	}
	
	new String:map[PLATFORM_MAX_PATH];
	GetCurrentMap(map, PLATFORM_MAX_PATH);
	g_Array_CurrentPlugins = GetMapPlugins(map);
	
	if (g_NextMapMode[0] != '\0')
	{
		strcopy(g_NextMode, sizeof(g_NextMode), g_NextMapMode);
		g_NextMapMode[0] = '\0';
	}
	else
	{
		ChooseRandomMode(g_Array_CurrentPlugins, g_NextMode, sizeof(g_NextMode));
	}
}

public OnMapEnd()
{
	g_HasIntermissionStarted = false;
	
	ChangeGameMode(g_CurrentMode, false);
	
	if (g_Cvar_Medieval != INVALID_HANDLE)
	{
		new bool:bMedieval = GetConVarBool(g_Cvar_Medieval);
		
		if (bMedieval && !g_bNextMapMedieval)
		{
			SetConVarBool(g_Cvar_Medieval, false);
		}
		else if (g_bNextMapMedieval && !bMedieval)
		{
			SetConVarBool(g_Cvar_Medieval, true);
			g_bNextMapMedieval = false;
		}
	}
	
	if (g_hRetryTimer != INVALID_HANDLE)
	{
		g_bMapEnded = true;
		TriggerTimer(g_hRetryTimer);
	}
}

public Action:Cmd_CurrentMode(client, args)
{
	CreateTimer(0.0, Timer_CurrentRound, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

public OnClientPutInServer(client)
{
	CreateTimer(15.0, Timer_CurrentRound, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

public Action:Timer_CurrentRound(Handle:timer, any:userid)
{
	new client = GetClientOfUserId(userid);
	if (client == 0)
		return;
	
	ReplyToCommand(client, "%t", "OIMM Current Mode", g_CurrentMode);
}

// Stuff to track when the map will end

public CvarNextMap(Handle:convar, const String:oldValue[], const String:newValue[])
{
	if (!IsMapValid(newValue))
	{
		return;
	}
	
	// Do votey and decidey stuff here
	SharedEndMapLogic(newValue);
}

Handle:GetMapPlugins(const String:map[])
{
	KvRewind(g_Kv_Plugins);
	
	if (!KvGotoFirstSubKey(g_Kv_Plugins))
	{
		return INVALID_HANDLE;
	}

	new Handle:array_PluginNames = CreateArray(ByteCountToCells(64));
	
	do
	{
		new Handle:validateMap = Handle:KvGetNum(g_Kv_Plugins, VALIDATE_FORWARD, _:INVALID_HANDLE);
		
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
			
			PushArrayString(array_PluginNames, name);
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
	
	ChangeGameMode(g_CurrentMode, false);
	
	if (g_NextMode[0] == '\0')
	{
		g_NextMode = STANDARD;
	}
	
	ChangeGameMode(g_NextMode, true);
	
	strcopy(g_CurrentMode, sizeof(g_CurrentMode), g_NextMode);
	g_NextMode[0] = '\0';
	
	PrintTranslationToAll(g_CurrentMode, "OIMM Current Mode");
	
	return Plugin_Continue;
}

ProcessModeKeyValues(const String:gameMode[], bool:enable)
{
	decl String:key[8];
	if (enable)
	{
		key = "enable";
	}
	else
	{
		key = "disable";
	}
	
	decl String:filename[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, filename, sizeof(filename), "%s/%s", CONFIGS, gameMode);
	
	new Handle:kvCommands = CreateKeyValues("oimm-commands");
	
	if (FileToKeyValues(kvCommands, filename) && KvJumpToKey(kvCommands, gameMode) && KvJumpToKey(kvCommands, key) && KvGotoFirstSubKey(kvCommands, false))
	{
		do
		{
			decl String:value[128];
			KvGetString(kvCommands, NULL_STRING, value, sizeof(value));
			ServerCommand("%s", value);
		} while (KvGotoNextKey(kvCommands, false));
	}
}

ChangeGameMode(const String:gameMode[], bool:enabled)
{
	KvRewind(g_Kv_Plugins);
	if (!StrEqual(gameMode, STANDARD) && !StrEqual(gameMode, MEDIEVAL))
	{
		if (!KvJumpToKey(g_Kv_Plugins, gameMode))
		{
			LogError("Could not find mode: %s", gameMode);
		}
		else
		{
			new Handle:statusForward = Handle:KvGetNum(g_Kv_Plugins, STATUS_FORWARD, _:INVALID_HANDLE);
			if (statusForward == INVALID_HANDLE)
			{
				LogError("Could not find Status Changed forward for mode: %s", gameMode);
			}
			else
			{
				Call_StartForward(statusForward);
				Call_PushCell(enabled);
				Call_Finish();
			}
		}			
	}
	
	ProcessModeKeyValues(gameMode, enabled);
	ProcessModeKeyValues("all", enabled);	
}

ChooseRandomMode(Handle:validPlugins, String:mode[], maxlength)
{
	new size = GetArraySize(validPlugins);
	
	GetArrayString(validPlugins, GetRandomInt(0, size - 1), mode, maxlength);
}

public Event_TFRestartRound(Handle:event, const String:name[], bool:dontBroadcast)
{
	/* Game got restarted - reset our round count tracking */
	g_TotalRounds = 0;	
}

public Event_Intermission(Handle:event, const String:name[], bool:dontBroadcast)
{
	g_HasIntermissionStarted = true;
}

public Event_PhaseEnd(Handle:event, const String:name[], bool:dontBroadcast)
{
	/* announce_phase_end fires for both half time and the end of the map, but intermission fires first for end of the map. */
	if (g_HasIntermissionStarted)
	{
		return;
	}

	/* No intermission yet, so this must be half time. Swap the score counters. */
	new t_score = g_winCount[2];
	g_winCount[2] =  g_winCount[3];
	g_winCount[3] = t_score;
}

public Event_RoundEnd(Handle:event, const String:name[], bool:dontBroadcast)
{
	new winner;
	if (strcmp(name, "round_win") == 0 || strcmp(name, "dod_round_win") == 0)
	{
		// Nuclear Dawn & DoD:S
		winner = GetEventInt(event, "team");
	}
	else
	{
		winner = GetEventInt(event, "winner");
	}	
	
	if (winner > 1)
	{
		g_winCount[winner]++;
	}
	
	if (winner >= MAXTEAMS)
	{
		SetFailState("Mod exceed maximum team count - Please file a bug report.");	
	}
	
	g_TotalRounds++;
	
	new bool:lastRound = IsLastRound(g_winCount[winner], g_TotalRounds);

	DoMultiModVote(lastRound);
}

public Event_TeamPlayWinPanel(Handle:event, const String:name[], bool:dontBroadcast)
{
	new bluescore = GetEventInt(event, "blue_score");
	new redscore = GetEventInt(event, "red_score");
		
	if(GetEventInt(event, "round_complete") == 1 || StrEqual(name, "arena_win_panel"))
	{
		g_TotalRounds++;
		
		new bool:lastRound = false;
		
		switch(GetEventInt(event, "winning_team"))
		{
			case 3:
			{
				lastRound = IsLastRound(bluescore, g_TotalRounds);
			}
			case 2:
			{
				lastRound = IsLastRound(redscore, g_TotalRounds);
			}			
			//We need to do nothing on winning_team == 0 this indicates stalemate.
			default:
			{
				return;
			}			
		}
		DoMultiModVote(lastRound);
	}
}

public Event_MvMWinPanel(Handle:event, const String:name[], bool:dontBroadcast)
{
	new bool:lastRound = false;
	if (GetEventInt(event, "winning_team") == 2)
	{
		new objectiveEnt = EntRefToEntIndex(g_ObjectiveEnt);
		if (objectiveEnt != INVALID_ENT_REFERENCE)
		{
			new currentRound = GetEntProp(g_ObjectiveEnt, Prop_Send, "m_nMannVsMachineMaxWaveCount");
			new totalRounds = GetEntProp(g_ObjectiveEnt, Prop_Send, "m_nMannVsMachineWaveCount");
			if (currentRound == totalRounds)
			{
				lastRound = true;
			}
		}
	}
	DoMultiModVote(lastRound);
}

DoMultiModVote(bool:lastRound)
{
	if (lastRound || GetConVarInt(g_Cvar_Frequency) == Frequency_Map)
	{
		return;
	}
	
	new mode = GetConVarInt(g_Cvar_Mode);
	switch (mode)
	{
		case Mode_Random:
		{
			ChooseRandomMode(g_Array_CurrentPlugins, g_NextMode, sizeof(g_NextMode));
		}
		
		case Mode_Vote:
		{
			new time = GetConVarInt(g_Cvar_Bonusroundtime) - 2;
			new String:map[PLATFORM_MAX_PATH];
			GetCurrentMap(map, PLATFORM_MAX_PATH);
			PrepareVote(map, CloneHandle(g_Array_CurrentPlugins), time);
		}
		
		default:
		{
			return;
		}
		
	}
	
}

bool:IsLastRound(winner_score, roundcount)
{
	new bool:mapEnd = false;
	
	if (g_Cvar_Winlimit != INVALID_HANDLE)
	{
		new winlimit = GetConVarInt(g_Cvar_Winlimit);
		if (winlimit)
		{			
			if (winner_score >= winlimit)
			{
				mapEnd = true;
			}
		}
	}

	if (g_Cvar_Maxrounds != INVALID_HANDLE)
	{
		new maxrounds;
		
		if (g_RoundCounting == RoundCounting_ArmsRace)
		{
			maxrounds = GameRules_GetProp("m_iNumGunGameProgressiveWeaponsCT");
		}
		else if (g_RoundCounting == RoundCounting_MvM)
		{
			maxrounds = GetEntProp(g_ObjectiveEnt, Prop_Send, "m_nMannVsMachineMaxWaveCount");
		}
		else if (g_Cvar_Maxrounds != INVALID_HANDLE)
		{
			maxrounds = GetConVarInt(g_Cvar_Maxrounds);
		}
		
		if (maxrounds)
		{
			if (roundcount >= maxrounds)
			{
				mapEnd = true;
			}
			else
			if (g_Cvar_MatchClinch != INVALID_HANDLE && GetConVarBool(g_Cvar_MatchClinch))
			{
				new winlimit = RoundFloat(maxrounds / 2.0);

				if(winner_score >= winlimit - 1)
				{
					mapEnd = true;
				}
			}
		}
	}
	
	new timeLeft;
	GetMapTimeLeft(timeLeft);
	
	switch (g_EngineVersion)
	{
		case Engine_TF2:
		{
			new bool:isMvM = bool:GameRules_GetProp("m_bPlayingMannVsMachine");
			new bool:isArena = GameRules_GetProp("m_nGameType") == TF2_GameType_Arena;
			
			if (!isArena && !isMvM)
			{
				if (timeLeft <= 300)
				{
					mapEnd = true;
				}
			}
			else if (isArena)
			{
				if (timeLeft <= 0)
				{
					mapEnd = true;
				}
			}
		}
		
		default:
		{
			if (timeLeft <= 0)
			{
				mapEnd = true;
			}
		}
	}

	return mapEnd;
}

SharedEndMapLogic(const String:map[])
{
	new modes = GetConVarInt(g_Cvar_Mode);
	if (modes == Mode_Vote)
	{
		new Handle:validPlugins = GetMapPlugins(map);
		
		if (GetArraySize(validPlugins) == 0)
		{
			return;
		}
		
		PrepareVote(map, validPlugins, 15);
	}
}

PrepareVote(const String:map[], Handle:validPlugins, time, bool:nextMap = false)
{
	// This array WILL be closed by this function
	new size = GetArraySize(validPlugins);

	// No valid plugins and Medieval mode is off means no vote, default to standard
	if (size == 0 && (g_EngineVersion != Engine_TF2 || !GetConVarBool(g_Cvar_MedievalAvailable)))
	{
		strcopy(g_NextMapMode, sizeof(g_NextMapMode), STANDARD);
		CloseHandle(validPlugins);
		return;
	}
	
	new slotsNeeded = size;
	
	if (GetConVarBool(g_Cvar_StandardAvailable))
		slotsNeeded++;
		
	if (g_EngineVersion == Engine_TF2 && GetConVarBool(g_Cvar_MedievalAvailable))
		slotsNeeded++;
		
	// NativeVotes only supports up to 5 slots on TF2
	new bool:useNativeVotes = g_bNativeVotes && GetConVarBool(g_Cvar_UseNativeVotes) && slotsNeeded <= NativeVotes_GetMaxItems();

	if ((useNativeVotes && NativeVotes_IsVoteInProgress()) || (!useNativeVotes && IsVoteInProgress()))
	{
		// Retry since a vote is currently active
		new Handle:data;
		g_hRetryTimer = CreateDataTimer(5.0, Timer_RetryVote, data, TIMER_FLAG_NO_MAPCHANGE);
		WritePackCell(data, _:validPlugins);
		WritePackString(data, map);
		WritePackCell(data, time);
		WritePackCell(data, _:nextMap);
		ResetPack(data);
	}
	
	new Handle:vote;
	
	new frequency = GetConVarInt(g_Cvar_Frequency);
	
	new String:voteTitle[128];
	
	switch (frequency)
	{
		case Frequency_Map:
		{
			voteTitle = "OIMM Vote Mode NextMap";
		}
		
		case Frequency_Round:
		{
			if (nextMap)
			{
				voteTitle = "OIMM Vote Mode NextMap FirstRound";
			}
			else
			{
				voteTitle = "OIMM Vote Mode NextRound";
			}
		}
	}
	
	if (nextMap && g_Cvar_Medieval != INVALID_HANDLE && GetConVarBool(g_Cvar_MedievalAvailable))
	{
		PushArrayString(validPlugins, MEDIEVAL);
	}
	
	if (GetConVarBool(g_Cvar_StandardAvailable))
	{
		PushArrayString(validPlugins, STANDARD);
	}

	if (useNativeVotes)
	{
		vote = NativeVotes_Create(NV_VoteHandler, NativeVotesType_Custom_Mult, NATIVEVOTES_ACTIONS_DEFAULT|MenuAction_Display|MenuAction_DisplayItem);
		NativeVotes_SetTitle(vote, voteTitle);
		NativeVotes_SetDetails(vote, map);
	}
	else
	{
		vote = CreateMenu(VoteHandler, MENU_ACTIONS_DEFAULT|MenuAction_Display|MenuAction_DisplayItem|MenuAction_VoteEnd);
		SetMenuTitle(vote, "%s", voteTitle);
	}
	
	if (GetConVarBool(g_Cvar_StandardAvailable))
	{
		new String:prefix[10];
		SplitString(map, "_", prefix, sizeof(prefix));
		
		if (FindStringInArray(g_hMapPrefixes, prefix))
		{
			AddVoteItem(vote, useNativeVotes, STANDARD, "Standard");
		}
	}
		
	if (nextMap && g_EngineVersion == Engine_TF2 && GetConVarBool(g_Cvar_MedievalAvailable))
	{
		AddVoteItem(vote, useNativeVotes, MEDIEVAL, "Standard Medieval");
	}
	
	// Fisher-Yates shuffle
	for (new i = size - 1; i >= 1; i--)
	{
		new j = GetRandomInt(0, i);
		SwapArrayItems(validPlugins, j, i);
	}
	
	for (new i = 0; i < size; ++i)
	{
		new String:pluginName[64];
		GetArrayString(validPlugins, i, pluginName, sizeof(pluginName));
		
		AddVoteItem(vote, useNativeVotes, pluginName, pluginName);
	}
	
	CloseHandle(validPlugins);

	if (useNativeVotes)
	{
		NativeVotes_DisplayToAll(vote, time);
	}
	else
	{
		VoteMenuToAll(vote, time);
	}
}

public Action:Timer_RetryVote(Handle:timer, Handle:data)
{
	new Handle:validPlugins = Handle:ReadPackCell(data);
	g_hRetryTimer = INVALID_HANDLE;
	if (g_bMapEnded)
	{
		CloseHandle(validPlugins);
		return Plugin_Stop;
	}
	
	new String:map[PLATFORM_MAX_PATH];
	ReadPackString(data, map, PLATFORM_MAX_PATH);
	new time = ReadPackCell(data);
	new bool:nextMap = bool:ReadPackCell(data);
	PrepareVote(map, validPlugins, time, nextMap);
	return Plugin_Continue;
}

public NV_VoteHandler(Handle:menu, MenuAction:action, param1, param2)
{
	switch (action)
	{
		// Only call this for non-NativeVotes
		case MenuAction_Display:
		{
			new String:voteTitle[50];
			new String:buffer[256];
			
			NativeVotes_GetTitle(menu, voteTitle, sizeof(voteTitle));
			Format(buffer, sizeof(buffer), "%T", voteTitle, param1);
			
			return _:NativeVotes_RedrawVoteTitle(buffer);
		}
		
		case MenuAction_End:
		{
			NativeVotes_Close(menu);
		}
		
		case MenuAction_VoteCancel:
		{
			if (param1 == VoteCancel_NoVotes)
			{
				NativeVotes_DisplayFail(menu, NativeVotesFail_NotEnoughVotes);
			}
			else
			{
				NativeVotes_DisplayFail(menu, NativeVotesFail_Generic);
			}
		}
		
		case MenuAction_VoteEnd:
		{
			new String:winner[64];
			NativeVotes_GetItem(menu, param1, winner, sizeof(winner));
			
			new String:translation[64];
			new String:voteTitle[64];
			
			NativeVotes_GetTitle(menu, voteTitle, sizeof(voteTitle));
			
			if (StrEqual(voteTitle, "OIMM Vote Mode NextMap"))
			{
				translation = "OIMM Next Map Mode";
				strcopy(g_NextMapMode, sizeof(g_NextMapMode), winner);
				if (StrEqual(winner, MEDIEVAL))
				{
					g_bNextMapMedieval = true;
				}
			}
			else if (StrEqual(voteTitle, "OIMM Vote Mode NextMap FirstRound"))
			{
				translation = "OIMM Next Map First Round Mode";
				strcopy(g_NextMapMode, sizeof(g_NextMapMode), winner);
				if (StrEqual(winner, MEDIEVAL))
				{
					g_bNextMapMedieval = true;
				}
			}
			else if (StrEqual(voteTitle, "OIMM Vote Mode NextRound"))
			{
				translation = "OIMM Next Round Mode";
				strcopy(g_NextMode, sizeof(g_NextMode), winner); // Note this is a different variable than the other two
			}
			
			for (new i = 1; i <= MaxClients; ++i)
			{
				if (!IsClientInGame(i) || IsFakeClient(i))
				{
					continue;
				}
				
				new String:transName[128];
				GetTranslatedName(winner, i, transName, sizeof(transName));

				NativeVotes_DisplayPassCustomToOne(menu, i, "%t", translation, transName);
				PrintHintText(i, "%t", translation, transName);
			}
		}
		
		case MenuAction_DisplayItem:
		{
			new String:item[128];
			NativeVotes_GetItem(menu, param2, item, sizeof(item));
			
			new String:buffer[128];
			
			if (StrEqual(item, MEDIEVAL))
			{
				Format(buffer, sizeof(buffer), "%T", "OIMM Medieval Mode", param1);
			}
			else if (StrEqual(item, STANDARD))
			{
				Format(buffer, sizeof(buffer), "%T", "OIMM Standard Mode", param1);
			}
			
			if (buffer[0] != '\0')
			{
				return _:NativeVotes_RedrawVoteItem(buffer);
			}
		}
	}
	return 0;
}

public VoteHandler(Handle:menu, MenuAction:action, param1, param2)
{
	switch (action)
	{
		// Only call this for non-NativeVotes
		case MenuAction_Display:
		{
			new String:voteTitle[50];
			new String:buffer[256];
			
			NativeVotes_GetTitle(menu, voteTitle, sizeof(voteTitle));
			Format(buffer, sizeof(buffer), "%T", voteTitle, param1);
			
			SetPanelTitle(Handle:param2, buffer);
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
			GetMenuItem(menu, param1, winner, sizeof(winner));
			
			new String:translation[64];
			new String:voteTitle[64];

			GetMenuTitle(menu, voteTitle, sizeof(voteTitle));
			
			if (StrEqual(voteTitle, "OIMM Vote Mode NextMap"))
			{
				translation = "OIMM Vote Win NextMap";
				strcopy(g_NextMapMode, sizeof(g_NextMapMode), winner);
				if (StrEqual(winner, MEDIEVAL))
				{
					g_bNextMapMedieval = true;
				}
			}
			else if (StrEqual(voteTitle, "OIMM Vote Mode NextMap FirstRound"))
			{
				translation = "OIMM Vote Win NextMap FirstRound";
				strcopy(g_NextMapMode, sizeof(g_NextMapMode), winner);
				if (StrEqual(winner, MEDIEVAL))
				{
					g_bNextMapMedieval = true;
				}
			}
			else if (StrEqual(voteTitle, "OIMM Vote Mode NextRound"))
			{
				translation = "OIMM Next Map First Round Mode";
				strcopy(g_NextMode, sizeof(g_NextMode), winner); // Note this is a different variable than the other two
			}
			
			for (new i = 1; i <= MaxClients; ++i)
			{
				if (!IsClientInGame(i) || IsFakeClient(i))
				{
					continue;
				}
				
				new String:transName[128];
				GetTranslatedName(winner, i, transName, sizeof(transName));
				
				NativeVotes_DisplayPassCustomToOne(menu, i, "%t", translation, transName);
				PrintHintText(i, "%t", translation, transName);
			}
		}
		
		case MenuAction_DisplayItem:
		{
			new String:item[128];
			GetMenuItem(menu, param2, item, sizeof(item));
			
			new String:buffer[128];
			
			if (StrEqual(item, MEDIEVAL))
			{
				Format(buffer, sizeof(buffer), "%T", "OIMM Medieval Mode", param1);
			}
			else if (StrEqual(item, STANDARD))
			{
				Format(buffer, sizeof(buffer), "%T", "OIMM Standard Mode", param1);
			}
			
			if (buffer[0] != '\0')
			{
				return RedrawMenuItem(buffer);
			}
		}
	}
	return 0;
}

public Native_Unregister(Handle:plugin, args)
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
	
	RemovePlugin(name);
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
	
	new Function:translator = GetNativeCell(4);
	
	AddPlugin(plugin, name, validateMap, statusChanged, translator);
}

AddPlugin(Handle:plugin, const String:name[], Function:validateMap, Function:statusChanged, Function:translator)
{
	new Handle:validateForward = INVALID_HANDLE;
	new Handle:statusForward = INVALID_HANDLE;
	new Handle:translateForward = INVALID_HANDLE;
	
	new bool:loaded = KvJumpToKey(g_Kv_Plugins, name);
	if (loaded)
	{
		LogMessage("Plugin already registered.  This can be caused by a plugin already being loaded with this name or not calling OptInMultiMod_Unregister in OnPluginEnd");
	}
	else
	{
		KvJumpToKey(g_Kv_Plugins, name, true); // Create this key
	}

	validateForward = Handle:KvGetNum(g_Kv_Plugins, VALIDATE_FORWARD, _:INVALID_HANDLE);
	statusForward = Handle:KvGetNum(g_Kv_Plugins, STATUS_FORWARD, _:INVALID_HANDLE);
	translateForward = Handle:KvGetNum(g_Kv_Plugins, TRANSLATE_FORWARD, _:INVALID_HANDLE);

	// If loaded, check the function counts.  If they're 0, then the plugin was never unregistered.
	// If they're > 0, a plugin is still loaded with this name
	if (loaded && (validateForward != INVALID_HANDLE && GetForwardFunctionCount(validateForward) > 0) ||
		(statusForward != INVALID_HANDLE && GetForwardFunctionCount(statusForward) > 0))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "A plugin named \"%s\" is already registered", name);
		return;
	}
	
	if (validateForward == INVALID_HANDLE)
	{
		validateForward = CreateForward(ET_Single, Param_String);
		KvSetNum(g_Kv_Plugins, VALIDATE_FORWARD, _:validateForward);
	}
	
	if (statusForward == INVALID_HANDLE)
	{
		statusForward = CreateForward(ET_Ignore, Param_Cell);
		KvSetNum(g_Kv_Plugins, STATUS_FORWARD, _:statusForward);
	}
	
	if (translateForward == INVALID_HANDLE)
	{
		translateForward = CreateForward(ET_Ignore, Param_Cell, Param_String, Param_Cell);
		KvSetNum(g_Kv_Plugins, TRANSLATE_FORWARD, _:translateForward);
	}
	
	AddToForward(validateForward, plugin, validateMap);
	AddToForward(statusForward, plugin, statusChanged);
	if (translator != INVALID_FUNCTION)
	{
		AddToForward(translateForward, plugin, translator);
	}
	KvRewind(g_Kv_Plugins);
}

RemovePlugin(const String:name[])
{
	KvRewind(g_Kv_Plugins);
	if (KvJumpToKey(g_Kv_Plugins, name))
	{
		new Handle:validateForward = Handle:KvGetNum(g_Kv_Plugins, VALIDATE_FORWARD, _:INVALID_HANDLE);
		if (validateForward != INVALID_HANDLE)
		{
			CloseHandle(validateForward);
		}
		
		new Handle:statusChanged = Handle:KvGetNum(g_Kv_Plugins, STATUS_FORWARD, _:INVALID_HANDLE);
		if (statusChanged != INVALID_HANDLE)
		{
			CloseHandle(statusChanged);
		}
		
		new Handle:translateName = Handle:KvGetNum(g_Kv_Plugins, TRANSLATE_FORWARD, _:INVALID_HANDLE);
		if (translateName != INVALID_HANDLE)
		{
			CloseHandle(translateName);
		}
		
		KvDeleteThis(g_Kv_Plugins);
		KvRewind(g_Kv_Plugins);
	}
}

AddVoteItem(Handle:vote, bool:nativeVotes, const String:item[], const String:display[])
{
	if (nativeVotes)
	{
		NativeVotes_AddItem(vote, item, display);
	}
	else
	{
		AddMenuItem(vote, item, display);
	}
}

GetTranslatedName(const String:plugin[], client, String:transName[], maxlength)
{
	if (!IsClientInGame(client) || IsFakeClient(client))
	{
		transName[0] = '\0';
		return;
	}
	
	KvRewind(g_Kv_Plugins);
	
	if (StrEqual(plugin, STANDARD))
	{
		Format(transName, maxlength, "%T", "OIMM Standard Mode", client);
	}
	else if (StrEqual(plugin, MEDIEVAL))
	{
		Format(transName, maxlength, "%T", "OIMM Medieval Mode", client);
	}
	else if (KvJumpToKey(g_Kv_Plugins, plugin))
	{
		new Handle:translateForward = Handle:KvGetNum(g_Kv_Plugins, TRANSLATE_FORWARD, _:INVALID_HANDLE);
		if (translateForward != INVALID_HANDLE)
		{
			Call_StartForward(translateForward);
			Call_PushCell(client);
			Call_PushStringEx(transName, maxlength, SM_PARAM_STRING_COPY|SM_PARAM_STRING_UTF8, SM_PARAM_COPYBACK);
			Call_PushCell(maxlength);
		}
		
		if (transName[0] == '\0')
		{
			strcopy(transName, maxlength, plugin);
		}
		
		KvGoBack(g_Kv_Plugins);
	}
	else
	{
		LogError("Could not find plugin");
		transName[0] = '\0';
	}
}

PrintTranslationToAll(const String:plugin[], const String:translation[])
{
	for (new i = 1; i <= MaxClients; ++i)
	{
		if (!IsClientInGame(i) || IsFakeClient(i))
		{
			continue;
		}
		
		new String:transName[128];
		GetTranslatedName(plugin, i, transName, sizeof(transName));
		
		PrintHintText(i, "%t", translation, transName);
	}
}
