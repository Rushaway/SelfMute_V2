#pragma semicolon 1

#include <sourcemod>
#include <sdktools>
#include <cstrike>
#include <multicolors>
#include <clientprefs>
#include <ccc>

#undef REQUIRE_PLUGIN
#tryinclude <zombiereloaded>
#tryinclude <Voice>
#define REQUIRE_PLUGIN

/* If your server doesn't have zombiereloaded but you have the zombiereloaded include file, then uncomment this: */
/*
#if defined _zr_included
#undef _zr_included
#endif
*/

#pragma newdecls required

#define DEBUG

#define PLUGIN_PREFIX "{green}[Self-Mute]{default}"

/* Please remove this when you compile the plugin, i did this because i dont have the include file */
// native bool IsClientTalking(int client);
// native void CCC_UpdateIgnoredArray(bool[] array);

/* Other plugins library checking variables */
bool g_Plugin_ccc;
bool g_Plugin_zombiereloaded;

/* Late Load */
bool g_bLate;

/* CCC ignoring variable */
bool g_Ignored[(MAXPLAYERS + 1) * (MAXPLAYERS + 1)];

/* Client Boolean variables */
bool g_bClientText[MAXPLAYERS + 1][MAXPLAYERS + 1];
bool g_bClientVoice[MAXPLAYERS + 1][MAXPLAYERS + 1];
bool g_bClientGroupText[MAXPLAYERS + 1][view_as<int>(GROUP_MAX_NUM)];
bool g_bClientGroupVoice[MAXPLAYERS + 1][view_as<int>(GROUP_MAX_NUM)];

/* ProtoBuf bool */
bool g_bIsProtoBuf = false;

/* Sqlite bool */
bool g_bSQLLite = false;

/* ConVar List */
ConVar g_cvMuteAdmins;
ConVar g_cvMuteAdminsPerma;
ConVar g_cvDefaultMuteTypeSettings;
ConVar g_cvDefaultMuteDurationSettings;

/* Enums & Structs */
enum MuteType {
	MuteType_Voice = 0,
	MuteType_Text = 1,
	MuteType_All = 2,
	MuteType_AskFirst = 3,
	MuteType_None = 4
};

enum MuteDuration {
	MuteDuration_Temporary = 0,
	MuteDuration_Permanent = 1,
	MuteDuration_AskFirst = 2
};

enum MuteTarget {
	MuteTarget_Client = 0,
	MuteTarget_Group = 1
};

enum GroupFilter {
	GROUP_ALL = 0,
	GROUP_CTS = 1,
	GROUP_TS = 2,
	GROUP_SPECTATORS = 3,
	GROUP_MAX_NUM = 4
};

char g_sGroupsNames[][] = {
	"All Players",
#if defined _zr_included
	"Humans",
	"Zombies",
#else
	"Counter Terrorists",
	"Terrorists",
#endif
	"Spectators"
};

char g_sGroupsFilters[][] = {
	"@all",
	"@cts",
	"@ts",
	"@spectators"
};

enum struct PlayerData {
	char name[32];
	char steamID[20];
	MuteType muteType;
	MuteDuration muteDuration;
	ArrayList mutesList;
	bool addedToDB;
	
	void Reset() {
		this.name[0] = '\0';
		this.steamID[0] = '\0';
		this.muteType = view_as<MuteType>(g_cvDefaultMuteTypeSettings.IntValue);
		this.muteDuration = view_as<MuteDuration>(g_cvDefaultMuteDurationSettings.IntValue);
		delete this.mutesList;
		this.addedToDB = false;
	}
	
	void Setup(char[] nameEx, char[] steamIDEx, MuteType muteTypeEx, MuteDuration muteDurationEx) {
		strcopy(this.name, sizeof(PlayerData::name), nameEx);
		strcopy(this.steamID, sizeof(PlayerData::steamID), steamIDEx);
		this.muteType = muteTypeEx;
		this.muteDuration = muteDurationEx;
		this.mutesList = new ArrayList(ByteCountToCells(1024));
		this.addedToDB = false;
	}
}

enum struct SelfMute {
	char name[32]; // targetName for mute and groupName for groups mute
	char id[20]; // targetSteaID for clients mute and groupFilter for groups mute
	MuteType muteType;
	MuteTarget muteTarget;
	
	void AddMute(char[] nameEx, char[] idEx, MuteType muteTypeEx, MuteTarget muteTargetEx) {
		strcopy(this.name, sizeof(SelfMute::name), nameEx);
		strcopy(this.id, sizeof(SelfMute::id), idEx);
		this.muteType = muteTypeEx;
		this.muteTarget = muteTargetEx;
	}
}

/* Player Data */
PlayerData g_PlayerData[MAXPLAYERS + 1];


/* Database */
Database g_hDB;

public Plugin myinfo = {
	name 			= "SelfMute V2",
	author 			= "Dolly",
	description 	= "Ignore other players in text and voicechat.",
	version 		= "1.1.4",
	url 			= ""
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max) {
	RegPluginLibrary("SelfMute");
	CreateNative("SelfMute_GetTextSelfMute", Native_GetTextSelfMute);
	CreateNative("SelfMute_GetVoiceSelfMute", Native_GetVoiceSelfMute);
	g_bLate = late;
	return APLRes_Success;
}

int Native_GetTextSelfMute(Handle plugin, int params) {
	int client = GetNativeCell(1);
	int target = GetNativeCell(2);
	return g_bClientText[client][target];
}

int Native_GetVoiceSelfMute(Handle plugin, int params) {
	int client = GetNativeCell(1);
	int target = GetNativeCell(2);
	return g_bClientVoice[client][target];
}

public void OnPluginStart() {
	/* Translation */
	LoadTranslations("common.phrases");
	
	/* ConVars */
	g_cvMuteAdmins 					= CreateConVar("sm_selfmute_mute_admins", "0", "Can mute admins? (0 = Admins can not be muted | 1 = Allow admins to be muted)");
	g_cvMuteAdminsPerma 			= CreateConVar("sm_selfmute_mute_admins_perm", "0", "Can mute admins permanently ? Dependency: sm_selfmute_mute_admins [0 = Can not | 1 = Can be]");
	g_cvDefaultMuteTypeSettings 		= CreateConVar("sm_selfmute_default_mute_type", "2", "[0 = Self-Mute Voice only | 1 = Self-Mute Text Only | 2 = Self-Mute Both]");
	g_cvDefaultMuteDurationSettings = CreateConVar("sm_selfmute_default_mute_duration", "2", "[0 = Temporary, 1 = Permanent, 2 = Ask First]");
	
	AutoExecConfig();
	
	/* Commands */
	RegConsoleCmd("sm_sm", Command_SelfMute, "Mute player by typing !sm [playername]");
	RegConsoleCmd("sm_selfmute", Command_SelfMute, "Mute player by typing !sm [playername]");
	
	RegConsoleCmd("sm_su", Command_SelfUnMute, "Unmute player by typing !su [playername]");
	RegConsoleCmd("sm_selfunmute", Command_SelfUnMute, "Unmute player by typing !su [playername]");
	
	RegConsoleCmd("sm_cm", Command_CheckMutes, "Check who you have self-muted");
	RegConsoleCmd("sm_suall", Command_SelfUnMuteAll, "Unmute all clients/groups");
	RegConsoleCmd("sm_smcookies", Command_SmCookies, "Choose the good cookie");
	
	/* Cookie Menu */
	SetCookieMenuItem(CookieMenu_Handler, 0, "SelfMute Cookies");
	
	/* Events */
	HookEvent("player_team", Event_PlayerTeam);
	
	/* Connect To DB */
	ConnectToDB();
	
	/* Prefix */
	CSetPrefix(PLUGIN_PREFIX);
	
	/* Radio Commands */
	if (GetFeatureStatus(FeatureType_Native, "GetUserMessageType") == FeatureStatus_Available && GetUserMessageType() == UM_Protobuf) {
		g_bIsProtoBuf = true;
	}
	
	UserMsg msgRadioText = GetUserMessageId("RadioText");
	UserMsg msgSendAudio = GetUserMessageId("SendAudio");

	if (msgRadioText == INVALID_MESSAGE_ID || msgSendAudio == INVALID_MESSAGE_ID) {
		SetFailState("This game doesnt support RadioText or SendAudio");
	}

	HookUserMessage(msgRadioText, Hook_UserMessageRadioText, true);
	HookUserMessage(msgSendAudio, Hook_UserMessageSendAudio, true);

	/* Incase of a late load */
	if (g_bLate) {
		for (int i = 1; i <= MaxClients; i++) {
			if (!IsClientInGame(i)) {
				continue;
			}
			
			if (IsClientAuthorized(i)) {
				OnClientPostAdminCheck(i);
			}
		}
	}
}

Action Command_SmCookies(int client, int args) {
	if (!client) {
		return Plugin_Handled;
	}
	
	ShowCookiesMenu(client);
	return Plugin_Handled;
}

void ShowCookiesMenu(int client) {
	Menu menu = new Menu(Menu_ShowCookies);
	menu.SetTitle("[SM] Choose your prefered cookie");
	
	menu.AddItem("0", "Mute Type, Text | Chat | Both | Ask First");
	menu.AddItem("1", "Mute Duration, Temporary | Permanent | Ask First");
	
	menu.ExitButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

int Menu_ShowCookies(Menu menu, MenuAction action, int param1, int param2) {
	switch(action) {
		case MenuAction_End: {
			delete menu;
		}
		
		case MenuAction_Select: {
			char option[2];
			menu.GetItem(param2, option, sizeof(option));
			if (StrEqual(option, "0")) {
				ShowCookiesMuteTypeMenu(param1);
			} else {
				ShowCookiesMuteDurationMenu(param1);
			}
		}
	}
	
	return 1;
}

void ShowCookiesMuteTypeMenu(int client) {
	Menu menu = new Menu(Menu_ShowCookiesMuteTypeMenu);
	menu.SetTitle("[SM] Choose your prefered cookie, how you want to self-mute a player or a group");
	
	menu.AddItem("0", "Voice Chat", g_PlayerData[client].muteType == view_as<MuteType>(0) ? ITEMDRAW_DISABLED : ITEMDRAW_DEFAULT);
	menu.AddItem("1", "Text Chat", g_PlayerData[client].muteType == view_as<MuteType>(1) ? ITEMDRAW_DISABLED : ITEMDRAW_DEFAULT);
	menu.AddItem("2", "Both Chats", g_PlayerData[client].muteType == view_as<MuteType>(2) ? ITEMDRAW_DISABLED : ITEMDRAW_DEFAULT);
	menu.AddItem("3", "Ask First", g_PlayerData[client].muteType == view_as<MuteType>(3) ? ITEMDRAW_DISABLED : ITEMDRAW_DEFAULT);
	
	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

void ShowCookiesMuteDurationMenu(int client) {
	Menu menu = new Menu(Menu_ShowCookiesMuteDurationMenu);
	menu.SetTitle("[SM] Choose your prefered cookie, how you want to self-mute a player or a group");
	
	menu.AddItem("0", "Temporary", g_PlayerData[client].muteDuration == view_as<MuteDuration>(0) ? ITEMDRAW_DISABLED : ITEMDRAW_DEFAULT);
	menu.AddItem("1", "Permanent", g_PlayerData[client].muteDuration == view_as<MuteDuration>(1) ? ITEMDRAW_DISABLED : ITEMDRAW_DEFAULT);
	menu.AddItem("2", "Ask First", g_PlayerData[client].muteDuration == view_as<MuteDuration>(2) ? ITEMDRAW_DISABLED : ITEMDRAW_DEFAULT);
	
	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

int Menu_ShowCookiesMuteTypeMenu(Menu menu, MenuAction action, int param1, int param2) {
	switch(action) {
		case MenuAction_End: {
			delete menu;
		}
		
		case MenuAction_Cancel: {
			if (param2 == MenuCancel_ExitBack) {
				ShowCookiesMenu(param1);
			}
		}
		
		case MenuAction_Select: {
			char option[2];
			menu.GetItem(param2, option, sizeof(option));
			MuteType muteType = view_as<MuteType>(StringToInt(option));
			g_PlayerData[param1].muteType = muteType;
			CPrintToChat(param1, "Cookie Saved!");
			ShowCookiesMuteTypeMenu(param1);
			DB_UpdateClientData(param1, 0); // 0 = mute type
		}
	}
	
	return 1;
}

int Menu_ShowCookiesMuteDurationMenu(Menu menu, MenuAction action, int param1, int param2) {
	switch(action) {
		case MenuAction_End: {
			delete menu;
		}
		
		case MenuAction_Cancel: {
			if (param2 == MenuCancel_ExitBack) {
				ShowCookiesMenu(param1);
			}
		}
		
		case MenuAction_Select: {
			char option[2];
			menu.GetItem(param2, option, sizeof(option));
			MuteDuration muteDuration = view_as<MuteDuration>(StringToInt(option));
			g_PlayerData[param1].muteDuration = muteDuration;
			CPrintToChat(param1, "Cookie Saved!");
			ShowCookiesMuteDurationMenu(param1);
			DB_UpdateClientData(param1, 1); // 1 = mute duration
		}
	}
	
	return 1;
}
Action Command_CheckMutes(int client, int args) {
	if (!client) {
		return Plugin_Handled;
	}
	
	ShowSelfMuteTargetsMenu(client);
	return Plugin_Handled;
}

Action Command_SelfUnMuteAll(int client, int args) {
	if (!client) {
		return Plugin_Handled;
	}
	
	if (!IsClientAuthorized(client)) {
		CReplyToCommand(client, "You need to be authorized to use this command. Please rejoin.");
		return Plugin_Handled;
	}
	
	for (int i = 1; i <= MaxClients; i++) {
		if (!IsClientInGame(i) || i == client) {
			continue;
		}
		
		if (g_bClientText[client][i] || g_bClientVoice[client][i]) {
			ApplySelfUnMute(client, i);
		}
	}
	
	for (int i = 0; i < view_as<int>(GROUP_MAX_NUM); i++) {
		if (g_bClientGroupText[client][i] || g_bClientGroupVoice[client][i]) {
			ApplySelfUnMuteGroup(client, view_as<GroupFilter>(i));
		}
	}
	
	CReplyToCommand(client, "You have self-unmuted all clients/groups.");
	return Plugin_Handled;
}

Action Command_SelfUnMute(int client, int args) {
	if (!client) {
		return Plugin_Handled;
	}
	
	if (!IsClientAuthorized(client)) {
		CReplyToCommand(client, "You need to be authorized to use this command. Please rejoin.");
		return Plugin_Handled;
	}
	
	if (!GetCmdArgs()) {
		OpenSelfMuteMenu(client);
		return Plugin_Handled;
	}
	
	char arg1[32];
	GetCmdArg(1, arg1, sizeof(arg1));
	
	if (arg1[0] == '@') {
		HandleGroupSelfUnMute(client, arg1);
		return Plugin_Handled;
	}
	
	int target = FindTarget(client, arg1, false, false);
	if (target == -1) {
		return Plugin_Handled;
	}
	
	if (target == client) {
		CReplyToCommand(client, "Silly, you cannot un-mute yourself!");
		return Plugin_Handled;
	}
	
	if (!g_bClientText[client][target] && !g_bClientVoice[client][target]) {
		CReplyToCommand(client, "You do not have this player self-muted.");
		return Plugin_Handled;
	}
	
	if (IsFakeClient(target) && !IsClientSourceTV(target)) {
		CReplyToCommand(client, "You cannot target a bot.");
		return Plugin_Handled;
	}
	
	HandleSelfUnMute(client, target);
	return Plugin_Handled;
}

void HandleSelfUnMute(int client, int target) {
	ApplySelfUnMute(client, target);
	
	CPrintToChat(client, "You have {green}self-unmuted {olive}%N", target);
}

void OpenSelfMuteMenu(int client) {
	Menu menu = new Menu(Menu_SelfMuteList);
	menu.SetTitle("[SM] Your self-muted Targets list");
	
	menu.AddItem("0", "Players self-mute List");
	menu.AddItem("1", "Groups self-mute List");
	
	menu.ExitButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

int Menu_SelfMuteList(Menu menu, MenuAction action, int param1, int param2) {
	switch(action) {
		case MenuAction_End: {
			delete menu;
		}
		
		case MenuAction_Select: {
			char option[2];
			menu.GetItem(param2, option, sizeof(option));
			ShowTargetsMenu(param1, view_as<MuteTarget>(StringToInt(option)));
		}
	}
	
	return 0;
}

void ShowTargetsMenu(int client, MuteTarget muteTarget) {
	Menu menu = new Menu(Menu_ShowTargets);
	
	char title[50];
	Format(title, sizeof(title), "%s - self-mute List", (muteTarget == MuteTarget_Client) ? "Players" : "Groups");
	menu.SetTitle(title);
					
	bool found = false;
	switch(muteTarget) {
		case MuteTarget_Client: {
			for (int i = 1; i <= MaxClients; i++) {
				if (i == client) {
					continue;
				}
				
				if (!IsClientInGame(i)) {
					continue;
				}
				
				if (g_bClientText[client][i] || g_bClientVoice[client][i]) {
					bool perma = IsThisMutedPerma(client, g_PlayerData[i].steamID, muteTarget);
					int userid = GetClientUserId(i);

					char itemInfo[12];
					FormatEx(itemInfo, sizeof(itemInfo), "0|%d", userid);
					char itemText[128];
					
					MuteType checkMuteType = GetMuteType(g_bClientText[client][i], g_bClientVoice[client][i]);

					FormatEx(itemText, sizeof(itemText), "(#%d) %s\nPermanent: %s\nVoice Chat: %s\nText Chat: %s",
														userid,
														g_PlayerData[i].name,
														perma ? "Yes" : "No",
														(checkMuteType == MuteType_All || checkMuteType == MuteType_Voice)
														? "Muted" : "Not Muted",
														(checkMuteType == MuteType_All || checkMuteType == MuteType_Text)
														? "Muted" : "Not Muted");						
					menu.AddItem(itemInfo, itemText);
					found = true;
				}
			}
		}
		
		case MuteTarget_Group: {
			for (int i = 0; i < view_as<int>(GROUP_MAX_NUM); i++) {
				if (g_bClientGroupText[client][i] || g_bClientGroupVoice[client][i]) {
					bool perma = IsThisMutedPerma(client, g_sGroupsFilters[i], muteTarget);
					
					char itemInfo[22];
					FormatEx(itemInfo, sizeof(itemInfo), "1|%s", g_sGroupsFilters[i]);
					
					char itemText[128];
					MuteType checkMuteType = GetMuteType(g_bClientGroupText[client][i], g_bClientGroupVoice[client][i]);

					FormatEx(itemText, sizeof(itemText), "%s\nPermanent: %s\nVoice Chat: %s\nText Chat: %s",
														g_sGroupsNames[i],
														perma ? "Yes" : "No",
														(checkMuteType == MuteType_All || checkMuteType == MuteType_Voice)
														? "Muted" : "Not Muted",
														(checkMuteType == MuteType_All || checkMuteType == MuteType_Text)
														? "Muted" : "Not Muted");
					menu.AddItem(itemInfo, itemText);	
					found = true;
				}
			}
		}
	}
	
	if (!found) {
		menu.AddItem(NULL_STRING, "No result was found!", ITEMDRAW_DISABLED);
	}
	
	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

int Menu_ShowTargets(Menu menu, MenuAction action, int param1, int param2) {
	switch(action) {
		case MenuAction_End: {
			delete menu;
		}
		
		case MenuAction_Cancel: {
			if (param2 == MenuCancel_ExitBack) {
				OpenSelfMuteMenu(param1);
			}
		}
		
		case MenuAction_Select: {
			char option[24];
			menu.GetItem(param2, option, sizeof(option));

			char options[2][14];
			ExplodeString(option, "|", options, 2, 14);

			MuteTarget muteTarget = view_as<MuteTarget>(StringToInt(options[0]));
			if (muteTarget == MuteTarget_Client) {
				int target = GetClientOfUserId(StringToInt(options[1]));
				if (!target) {
					CPrintToChat(param1, "Player is no longer available");
					return 1;
				}
				
				HandleSelfUnMute(param1, target);
			} else {
				HandleGroupSelfUnMute(param1, options[1]);
			}
			
			
			ShowTargetsMenu(param1, muteTarget);
		}
	}
	
	return 1;
}

Action Command_SelfMute(int client, int args) {
	if (!client) {
		return Plugin_Handled;
	}
	
	if (!IsClientAuthorized(client)) {
		CReplyToCommand(client, "You need to be authorized to use this command. Please rejoin.");
		return Plugin_Handled;
	}
	
	char arg1[32];
	GetCmdArg(1, arg1, sizeof(arg1));
	
	if (!GetCmdArgs()) {
		ShowSelfMuteTargetsMenu(client);
		return Plugin_Handled;
	}
	
	if (arg1[0] == '@') {
		HandleGroupSelfMute(client, arg1, g_PlayerData[client].muteType, g_PlayerData[client].muteDuration);
		return Plugin_Handled;
	}
	
	int target = FindTarget(client, arg1, false, false);
	if (target == -1) {
		return Plugin_Handled;
	}
	
	if (target == client) {
		CReplyToCommand(client, "Silly, you cannot mute yourself!");
		return Plugin_Handled;
	}

	if (!g_cvMuteAdmins.BoolValue && IsClientAdmin(target)) {
		CReplyToCommand(client, "You cannot self-mute an admin.");
		return Plugin_Handled;
	}
	
	if (IsFakeClient(target) && !IsClientSourceTV(target)) {
		CReplyToCommand(client, "You cannot target a bot.");
		return Plugin_Handled;
	}
	
	HandleClientSelfMute(client, target, g_PlayerData[client].muteType, g_PlayerData[client].muteDuration);
	return Plugin_Handled;
}

void ShowSelfMuteTargetsMenu(int client) {
	Menu menu = new Menu(Menu_ShowSelfMuteTargets);
	menu.SetTitle("[SM] Choose who you want to self-mute");
	
	menu.AddItem("0", "Players self-mute List");
	menu.AddItem("1", "Groups self-mute List");
	
	menu.ExitButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

int Menu_ShowSelfMuteTargets(Menu menu, MenuAction action, int param1, int param2) {
	switch(action) {
		case MenuAction_End: {
			delete menu;
		}
		
		case MenuAction_Select: {
			char option[2];
			menu.GetItem(param2, option, sizeof(option)); 
			
			MuteTarget muteTarget = view_as<MuteTarget>(StringToInt(option));
			ShowSelfMuteSpecificTargets(param1, muteTarget);
		}
	}
	
	return 1;
}

void ShowSelfMuteSpecificTargets(int client, MuteTarget muteTarget) {
	Menu menu = new Menu(Menu_ShowSelfMuteSpecificTargets);
	
	char title[75];
	FormatEx(title, sizeof(title), "[SM] %s to self-mute [TEXT CHAT] [VOICE CHAT]", muteTarget == MuteTarget_Client ? "Players" : "Groups");
	menu.SetTitle(title);
	
	switch(muteTarget) {
		case MuteTarget_Client: {
			for (int i = 1; i <= MaxClients; i++) {
				if (!IsClientInGame(i)) {
					continue;
				}
				
				if (i == client) {
					continue;
				}
				
				if (IsFakeClient(i) && !IsClientSourceTV(i)) {
					continue;
				}
				
				if (!IsClientAuthorized(i)) {
					continue;
				}
				
				int userid = GetClientUserId(i);
				
				char itemInfo[12];
				FormatEx(itemInfo, sizeof(itemInfo), "0|%d", userid);
				
				char itemText[128];
				FormatEx(itemText, sizeof(itemText), "[#%d] %s - [%s] [%s]", userid, g_PlayerData[i].name, g_bClientText[client][i] ? "X" : "",
														g_bClientVoice[client][i] ? "X" : "");
														
				menu.AddItem(itemInfo, itemText, (g_bClientText[client][i] && g_bClientVoice[client][i]) ? ITEMDRAW_DISABLED : ITEMDRAW_DEFAULT);
			}
		}
		
		case MuteTarget_Group: {
			for (int i = 0; i < view_as<int>(GROUP_MAX_NUM); i++) {
				char itemInfo[22];
				FormatEx(itemInfo, sizeof(itemInfo), "1|%s", g_sGroupsFilters[i]);
				
				char itemText[128];
				FormatEx(itemText, sizeof(itemText), "%s - [%s] [%s]", g_sGroupsNames[i], g_bClientGroupText[client][i] ? "X" : "",
														g_bClientGroupVoice[client][i] ? "X" : "");
														
				menu.AddItem(itemInfo, itemText, (g_bClientGroupText[client][i] && g_bClientGroupVoice[client][i]) ? ITEMDRAW_DISABLED : ITEMDRAW_DEFAULT);
			}
		}
	}
	
	menu.ExitButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

int Menu_ShowSelfMuteSpecificTargets(Menu menu, MenuAction action, int param1, int param2) {
	switch(action) {
		case MenuAction_End: {
			delete menu;
		}
		
		case MenuAction_Cancel: {
			if (param2 == MenuCancel_ExitBack) {
				ShowSelfMuteTargetsMenu(param1);
			}
		}
		
		case MenuAction_Select: {
			char option[24];
			menu.GetItem(param2, option, sizeof(option));
			
			char options[2][14];
			ExplodeString(option, "|", options, 2, 14);
			
			MuteTarget muteTarget = view_as<MuteTarget>(StringToInt(options[0]));
			if (muteTarget == MuteTarget_Client) {
				int target = GetClientOfUserId(StringToInt(options[1]));
				if (!target) {
					CPrintToChat(param1, "Player is no longer available");
					return 1;
				}
				
				MuteType muteType = GetMuteType(g_bClientText[param1][target], g_bClientVoice[param1][target]);
				if (muteType == MuteType_All) {
					return 1;
				}
				
				if (muteType == g_PlayerData[param1].muteType) {
					CPrintToChat(param1, "You have already self-muted this player. If you want to self-mute another type of chat please change your settings in {olive}!smcookies");
					ShowSelfMuteSpecificTargets(param1, muteTarget);
					return 1;
				}
				
				HandleClientSelfMute(param1, target, g_PlayerData[param1].muteType, g_PlayerData[param1].muteDuration);
			} else {
				GroupFilter groupFilter = GetGroupFilterByChar(options[1]);
				
				MuteType muteType = GetMuteType(g_bClientGroupText[param1][view_as<int>(groupFilter)], g_bClientGroupVoice[param1][view_as<int>(groupFilter)]);
				if (muteType == MuteType_All) {
					return 1;
				}
				
				if (muteType == g_PlayerData[param1].muteType) {
					CPrintToChat(param1, "You have already self-muted this group. If you want to self-mute another type of chat please change your settings in {olive}!smcookies");
					ShowSelfMuteSpecificTargets(param1, muteTarget);
					return 1;
				}
				
				HandleGroupSelfMute(param1, options[1], g_PlayerData[param1].muteType, g_PlayerData[param1].muteDuration);
			}
			
			if (g_PlayerData[param1].muteType != MuteType_AskFirst && g_PlayerData[param1].muteDuration != MuteDuration_AskFirst) {
				ShowSelfMuteSpecificTargets(param1, muteTarget);
			}
		}
	}
	
	return 1;
}

void HandleGroupSelfUnMute(int client, const char[] groupFilterC) {
	GroupFilter groupFilter = GROUP_MAX_NUM;
	for (int i = 0; i < sizeof(g_sGroupsFilters); i++) {
		if (strcmp(groupFilterC, g_sGroupsFilters[i], false) == 0) {
			groupFilter = view_as<GroupFilter>(i);
			break;
		}
	}
	
	if (groupFilter == GROUP_MAX_NUM) {
		CPrintToChat(client, "Cannot find the specified group.");
		return;
	}
	
	if (!g_bClientGroupText[client][view_as<int>(groupFilter)] && !g_bClientGroupVoice[client][view_as<int>(groupFilter)]) {
		CPrintToChat(client, "You do not have this group self-muted.");
		return;
	}
	
	ApplySelfUnMuteGroup(client, groupFilter);
	CPrintToChat(client, "You have {green}self-unmuted {olive}%s Group", g_sGroupsNames[view_as<int>(groupFilter)]);
}

void HandleGroupSelfMute(int client, const char[] groupFilterC, MuteType muteType, MuteDuration muteDuration) {
	#if defined _Voice_included
		if (strcmp(groupFilterC, "@talking", false) == 0) {
			for (int i = 1; i <= MaxClients; i++) {
				if (!IsClientInGame(i)) {
					continue;
				}

				if (!IsClientTalking(i)) {
					continue;
				}
				
				g_bClientVoice[client][i] = true;
				SetListenOverride(client, i, Listen_No);
			}
			return;
		}
	#endif
	
	GroupFilter groupFilter = GROUP_MAX_NUM;
	for (int i = 0; i < sizeof(g_sGroupsFilters); i++) {
		if (strcmp(groupFilterC, g_sGroupsFilters[i], false) == 0) {
			groupFilter = view_as<GroupFilter>(i);
			break;
		}
	}
	
	if (groupFilter == GROUP_MAX_NUM) {
		CPrintToChat(client, "Cannot find the specified group.");
		return;
	}
	
	/* we need to check if this client has selfmuted this target before */
	if ((g_bClientGroupText[client][view_as<int>(groupFilter)] && !g_bClientGroupVoice[client][view_as<int>(groupFilter)]) 
		&& (muteType == MuteType_Voice || muteType == MuteType_All)) {
			
		bool perma = IsThisMutedPerma(client, g_sGroupsFilters[view_as<int>(groupFilter)], MuteTarget_Group);
		muteDuration = (perma) ? MuteDuration_Permanent:MuteDuration_Temporary;
		StartSelfMuteGroup(client, groupFilter, MuteType_Voice, muteDuration);
		return;
	}
	
	if ((!g_bClientGroupText[client][view_as<int>(groupFilter)] && g_bClientGroupVoice[client][view_as<int>(groupFilter)]) && (muteType == MuteType_Text || muteType == MuteType_All)) {
		bool perma = IsThisMutedPerma(client, g_sGroupsFilters[view_as<int>(groupFilter)], MuteTarget_Group);
		muteDuration = (perma) ? MuteDuration_Permanent:MuteDuration_Temporary;
		StartSelfMuteGroup(client, groupFilter, MuteType_Text, muteDuration);
		return;
	}
	
	MuteType muteTypeEx = GetMuteType(g_bClientGroupText[client][view_as<int>(groupFilter)], g_bClientGroupVoice[client][view_as<int>(groupFilter)]);
	if (muteTypeEx == muteType) {
		CPrintToChat(client, "You have already self-muted this group for either voice or text chats or both!");
		return;
	}

	if (g_bClientGroupText[client][view_as<int>(groupFilter)] && g_bClientGroupVoice[client][view_as<int>(groupFilter)]) {
		CPrintToChat(client, "You have already self-muted this group for its voice and text chats!");
		return;
	}
	
	if (muteType != MuteType_AskFirst) {
		if ((g_bClientGroupText[client][view_as<int>(GROUP_ALL)] && muteType == MuteType_Text)
			|| (g_bClientGroupVoice[client][view_as<int>(GROUP_ALL)] && muteType == MuteType_Voice)
			|| (g_bClientGroupText[client][view_as<int>(GROUP_ALL)] && g_bClientGroupVoice[client][view_as<int>(GROUP_ALL)]
			&& muteType == MuteType_All)) {
			CPrintToChat(client, "You have already self-muted All Players Group, why do you want to self-mute any other group dummy.");
			return;
		}
		
		StartSelfMuteGroup(client, groupFilter, muteType, muteDuration);	
		return;
	}
	
	ShowMuteTypeMenuGroup(client, groupFilter);
} 

void HandleClientSelfMute(int client, int target, MuteType muteType, MuteDuration muteDuration) {
	if (!g_cvMuteAdminsPerma.BoolValue && muteDuration == MuteDuration_Permanent && IsClientAdmin(target)) {
		CPrintToChat(client, "You cannot self-mute an admin Permanently.");
		return;
	}
	
	/* we need to check if this client has selfmuted this target before */
	if ((g_bClientText[client][target] && !g_bClientVoice[client][target]) && (muteType == MuteType_Voice || muteType == MuteType_All)) {
		bool perma = IsThisMutedPerma(client, g_PlayerData[target].steamID, MuteTarget_Client);
		muteDuration = (perma) ? MuteDuration_Permanent:MuteDuration_Temporary;
		StartSelfMute(client, target, MuteType_Voice, muteDuration);
		return;
	}
	
	if ((!g_bClientText[client][target] && g_bClientVoice[client][target]) && (muteType == MuteType_Text || muteType == MuteType_All)) {
		bool perma = IsThisMutedPerma(client, g_PlayerData[target].steamID, MuteTarget_Client);
		muteDuration = (perma) ? MuteDuration_Permanent:MuteDuration_Temporary;
		StartSelfMute(client, target, MuteType_Text, muteDuration);
		return;
	}

	if (g_bClientText[client][target] && g_bClientVoice[client][target]) {
		CPrintToChat(client, "You have already self-muted this player for their voice and text chats!");
		return;
	}
	
	if (muteType != MuteType_AskFirst) {
		StartSelfMute(client, target, muteType, muteDuration);	
		return;
	}
	
	ShowMuteTypeMenu(client, target);
}

void ShowMuteTypeMenu(int client, int target) {
	MuteType muteType = GetMuteType(g_bClientText[client][target], g_bClientVoice[client][target]);
	
	Menu menu = new Menu(Menu_ShowMuteType);
	
	char title[128];
	FormatEx(title, sizeof(title), "[SM] Choose how you want to self-mute %N", target);
	menu.SetTitle(title);
	
	int userid = GetClientUserId(target);
	
	char data[12];
	
	int flags = ITEMDRAW_DEFAULT;
	if (muteType == MuteType_Voice) {
		flags = ITEMDRAW_DISABLED;
	}
	
	FormatEx(data, sizeof(data), "0|%d", userid);
	menu.AddItem(data, "Voice Chat Only", flags);
	
	if (muteType == MuteType_Text) {
		flags = ITEMDRAW_DISABLED;
	}
	
	FormatEx(data, sizeof(data), "1|%d", userid);
	menu.AddItem(data, "Text Chat Only", flags);
	
	FormatEx(data, sizeof(data), "2|%d", userid);
	menu.AddItem(data, "Both Text and Voice Chats");
	
	menu.ExitButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

int Menu_ShowMuteType(Menu menu, MenuAction action, int param1, int param2) {
	switch(action) {
		case MenuAction_End: {
			delete menu;
		}
		
		case MenuAction_Select: {
			char option[24];
			menu.GetItem(param2, option, sizeof(option));
			
			char data[2][12];
			ExplodeString(option, "|", data, sizeof(data), sizeof(data[]));
			
			int target = GetClientOfUserId(StringToInt(data[1]));
			if (!target) {
				PrintToChat(param1, "Userid: %s", data[1]);
				CPrintToChat(param1, "Player is no longer available.");
				return -1;
			}
			
			MuteType muteType = view_as<MuteType>(StringToInt(data[0]));
			HandleClientSelfMute(param1, target, muteType, g_PlayerData[param1].muteDuration);
		}
	}
	
	return 1;
}

void StartSelfMute(int client, int target, MuteType muteType, MuteDuration muteDuration) {
	switch(muteDuration) {
		case MuteDuration_Temporary: {
			ApplySelfMute(client, target, muteType);
			MuteType muteTypeEx = GetMuteType(g_bClientText[client][target], g_bClientVoice[client][target]);
			
			CPrintToChat(client, "You have {green}self-muted {olive}%N\n{default}Voice Chat: {olive}%s\n{default}Text Chat: {olive}%s", target,
						(muteTypeEx==MuteType_Voice||muteTypeEx==MuteType_All)?"Yes":"No",
						(muteTypeEx==MuteType_Text||muteTypeEx==MuteType_All)?"Yes":"No");
		}
		
		case MuteDuration_Permanent: {
			ApplySelfMute(client, target, muteType);
			MuteType muteTypeEx = GetMuteType(g_bClientText[client][target], g_bClientVoice[client][target]);
			
			CPrintToChat(client, "You have {green}self-muted {olive}%N\n{default}Voice Chat: {olive}%s\n{default}Text Chat: {olive}%s", target,
						(muteTypeEx==MuteType_Voice||muteTypeEx==MuteType_All)?"Yes":"No",
						(muteTypeEx==MuteType_Text||muteTypeEx==MuteType_All)?"Yes":"No");
						
			SaveSelfMuteClient(client, target);
			CPrintToChat(client, "The {olive}self-mute {default}has been saved!");
		}
		
		case MuteDuration_AskFirst: {
			ShowAlertMenu(client, target, muteType);
		}
	}
}

void ShowAlertMenu(int client, int target, MuteType muteType) {
	Menu menu = new Menu(Menu_ShowAlertMenu);
	
	char title[128];
	FormatEx(title, sizeof(title), "[SM] Choose how you want to self-mute %N", target);
	menu.SetTitle(title);
	
	int userid = GetClientUserId(target);
	
	char data[12];
	
	FormatEx(data, sizeof(data), "%d|0|%d", view_as<int>(muteType), userid);
	menu.AddItem(data, "Temporarily");
	
	FormatEx(data, sizeof(data), "%d|1|%d", view_as<int>(muteType), userid);
	menu.AddItem(data, "Permanently");
	
	menu.ExitButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

int Menu_ShowAlertMenu(Menu menu, MenuAction action, int param1, int param2) {
	switch(action) {
		case MenuAction_End: {
			delete menu;
		}
		
		case MenuAction_Select: {
			char option[24];
			menu.GetItem(param2, option, sizeof(option));
			
			char data[3][12];
			ExplodeString(option, "|", data, sizeof(data), sizeof(data[]));
			
			int target = GetClientOfUserId(StringToInt(data[2]));
			if (!target) {
				CPrintToChat(param1, "Player is no longer available.");
				return -1;
			}
			
			MuteType muteType = view_as<MuteType>(StringToInt(data[0]));
			MuteDuration muteDuration = view_as<MuteDuration>(StringToInt(data[1]));
			HandleClientSelfMute(param1, target, muteType, muteDuration);
		}
	}
	
	return 1;
}

void ShowMuteTypeMenuGroup(int client, GroupFilter groupFilter) {
	MuteType muteType = GetMuteType(g_bClientGroupText[client][view_as<int>(groupFilter)], g_bClientGroupVoice[client][view_as<int>(groupFilter)]);
	
	Menu menu = new Menu(Menu_ShowMuteTypeGroup);
	
	char title[128];
	FormatEx(title, sizeof(title), "[SM] Choose how you want to self-mute %s Group", g_sGroupsNames[view_as<int>(groupFilter)]);
	menu.SetTitle(title);
	
	int id = view_as<int>(groupFilter);
	
	char data[12];
	
	int flags = ITEMDRAW_DEFAULT;
	if (muteType == MuteType_Voice) {
		flags = ITEMDRAW_DISABLED;
	}
	
	FormatEx(data, sizeof(data), "0|%d", id);
	menu.AddItem(data, "Voice Chat Only", flags);
	
	flags = ITEMDRAW_DEFAULT;
	if (muteType == MuteType_Text) {
		flags = ITEMDRAW_DISABLED;
	}
	
	FormatEx(data, sizeof(data), "1|%d", id);
	menu.AddItem(data, "Text Chat Only", flags);
	
	FormatEx(data, sizeof(data), "2|%d", id);
	menu.AddItem(data, "Both Text and Voice Chats");
	
	menu.ExitButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

int Menu_ShowMuteTypeGroup(Menu menu, MenuAction action, int param1, int param2) {
	switch(action) {
		case MenuAction_End: {
			delete menu;
		}
		
		case MenuAction_Select: {
			char option[24];
			menu.GetItem(param2, option, sizeof(option));
			
			char data[2][12];
			ExplodeString(option, "|", data, sizeof(data), sizeof(data[]));
			
			MuteType muteType = view_as<MuteType>(StringToInt(data[0]));
			HandleGroupSelfMute(param1, g_sGroupsFilters[StringToInt(data[1])], muteType, g_PlayerData[param1].muteDuration);
		}
	}
	
	return 1;
}

void StartSelfMuteGroup(int client, GroupFilter groupFilter, MuteType muteType, MuteDuration muteDuration) {
	switch(muteDuration) {
		case MuteDuration_Temporary: {
			ApplySelfMuteGroup(client, g_sGroupsFilters[view_as<int>(groupFilter)], muteType);
			MuteType muteTypeEx = GetMuteType(g_bClientGroupText[client][view_as<int>(groupFilter)], g_bClientGroupVoice[client][view_as<int>(groupFilter)]);
			
			CPrintToChat(client, "You have {green}self-muted {olive}%s Group\n{default}Voice Chat: {olive}%s\n{default}Text Chat: {olive}%s", g_sGroupsNames[view_as<int>(groupFilter)],
						(muteTypeEx==MuteType_Voice||muteTypeEx==MuteType_All)?"Yes":"No",
						(muteTypeEx==MuteType_Text||muteTypeEx==MuteType_All)?"Yes":"No");
		}
		
		case MuteDuration_Permanent: {
			ApplySelfMuteGroup(client, g_sGroupsFilters[view_as<int>(groupFilter)], muteType);
			MuteType muteTypeEx = GetMuteType(g_bClientGroupText[client][view_as<int>(groupFilter)], g_bClientGroupVoice[client][view_as<int>(groupFilter)]);
			
			CPrintToChat(client, "You have {green}self-muted {olive}%s Group\n{default}Voice Chat: {olive}%s\n{default}Text Chat: {olive}%s", g_sGroupsNames[view_as<int>(groupFilter)],
						(muteTypeEx==MuteType_Voice||muteTypeEx==MuteType_All)?"Yes":"No",
						(muteTypeEx==MuteType_Text||muteTypeEx==MuteType_All)?"Yes":"No");
						
			SaveSelfMuteGroup(client, groupFilter);
			CPrintToChat(client, "The {olive}self-mute {default}has been saved!");
		}
		
		case MuteDuration_AskFirst: {
			ShowAlertMenuGroup(client, groupFilter, muteType);
		}
	}
}

void ShowAlertMenuGroup(int client, GroupFilter groupFilter, MuteType muteType) {
	Menu menu = new Menu(Menu_ShowAlertMenuGroup);
	
	char title[128];
	FormatEx(title, sizeof(title), "[SM] Choose how you want to self-mute %s Group", g_sGroupsNames[view_as<int>(groupFilter)]);
	menu.SetTitle(title);
	
	int id = view_as<int>(groupFilter);
	
	char data[12];
	
	FormatEx(data, sizeof(data), "%d|0|%d", view_as<int>(muteType), id);
	menu.AddItem(data, "Temporarily");
	
	FormatEx(data, sizeof(data), "%d|1|%d", view_as<int>(muteType), id);
	menu.AddItem(data, "Permanently");
	
	menu.ExitButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

int Menu_ShowAlertMenuGroup(Menu menu, MenuAction action, int param1, int param2) {
	switch(action) {
		case MenuAction_End: {
			delete menu;
		}
		
		case MenuAction_Select: {
			char option[24];
			menu.GetItem(param2, option, sizeof(option));
			
			char data[3][12];
			ExplodeString(option, "|", data, sizeof(data), sizeof(data[]));
			
			GroupFilter groupFilter = view_as<GroupFilter>(StringToInt(data[2]));
			MuteType muteType = view_as<MuteType>(StringToInt(data[0]));
			MuteDuration muteDuration = view_as<MuteDuration>(StringToInt(data[1]));
			HandleGroupSelfMute(param1, g_sGroupsFilters[view_as<int>(groupFilter)], muteType, muteDuration);
		}
	}
	
	return 1;
}
public void OnAllPluginsLoaded() {
	g_Plugin_ccc = LibraryExists("ccc");
	g_Plugin_zombiereloaded = LibraryExists("zombiereloaded");
}

void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast) {
	for (int i = 1; i <= MaxClients; i++) {
		if (!IsClientInGame(i) || IsFakeClient(i)) {
			continue;
		}
		
		SelfUnMutePreviousGroup(i);
		
		for (int j = 0; j < view_as<int>(GROUP_MAX_NUM); j++) {
			if (g_bClientGroupText[i][j] || g_bClientGroupVoice[i][j]) {
				UpdateSelfMuteGroup(i, view_as<GroupFilter>(j));
			}
		}
	}
}

/* Database Setup */
void ConnectToDB() {
	Database.Connect(DB_OnConnect, "SelfMuteV2");
}

public void DB_OnConnect(Database db, const char[] error, any data) {
	if (db == null || error[0]) {
		/* Failure happen. Do retry with delay */
		CreateTimer(15.0, DB_RetryConnection);
		#if defined DEBUG
			LogError("[Self-Mute] Couldn't connect to database `SelfMute`, retrying in 15 seconds. \nError: %s", error);
		#endif
		return;
	}

	PrintToServer("[Self-Mute] Successfully connected to database!");
	g_hDB = db;
	DB_Tables();
	g_hDB.SetCharset("utf8");

}

public Action DB_RetryConnection(Handle timer)
{
	if (g_hDB == null)
		ConnectToDB();
	
	return Plugin_Continue;
}

void DB_Tables() {
	if (g_hDB == null) {
		return;
	}
	
	char driver[32];
	g_hDB.Driver.GetIdentifier(driver, sizeof(driver));
	if (strcmp(driver, "mysql", false) == 0) {
		Transaction T_mysqlTables = SQL_CreateTransaction();
		
		char query0[1024];		
		g_hDB.Format(query0, sizeof(query0), "CREATE TABLE IF NOT EXISTS `clients_data`("
												... "`id` int(11) unsigned NOT NULL auto_increment," 
												... "`client_steamid` bigint unsigned NOT NULL," 
												... "`mute_type` int(2) NOT NULL,"
												... "`mute_duration` int(2) NOT NULL,"
												... "PRIMARY KEY(`id`))");
																								
		T_mysqlTables.AddQuery(query0);

		g_hDB.Format(query0, sizeof(query0), "CREATE TABLE IF NOT EXISTS `clients_mute`("
												... "`id` int(11) unsigned NOT NULL auto_increment," 
												... "`client_name` varchar(32) NOT NULL," 
												... "`client_steamid` bigint unsigned NOT NULL," 
												... "`target_name` varchar(32) NOT NULL," 
												... "`target_steamid` bigint unsigned NOT NULL," 
												... "`text_chat` int(2) NOT NULL,"
												... "`voice_chat` int(2) NOT NULL,"
												... "PRIMARY KEY(`id`),"
												... "UNIQUE KEY(`client_steamid`, `target_steamid`))");
																								
		T_mysqlTables.AddQuery(query0);

		g_hDB.Format(query0, sizeof(query0), "CREATE TABLE IF NOT EXISTS `groups_mute`("
												... "`id` int(11) unsigned NOT NULL auto_increment," 
												... "`client_name` varchar(32) NOT NULL," 
												... "`client_steamid` bigint unsigned NOT NULL," 
												... "`group_name` varchar(32) NOT NULL," 
												... "`group_filter` varchar(20) NOT NULL," 
												... "`text_chat` int(2) NOT NULL,"
												... "`voice_chat` int(2) NOT NULL,"
												... "PRIMARY KEY(`id`),"
												... "UNIQUE KEY(`client_steamid`, `group_filter`))");
														
		T_mysqlTables.AddQuery(query0);
	
		g_hDB.Format(query0, sizeof(query0), "CREATE INDEX `idx_client_steamid` ON `clients_data` (`client_steamid`);"
											..."CREATE INDEX `idx_clients_client_steamid` ON `clients_mute` (`client_steamid`);"
											..."CREATE INDEX `idx_clients_target_steamid` ON `clients_mute` (`target_steamid`);"
											..."CREATE INDEX `idx_groups_client_steamid` ON `groups_mute` (`client_steamid`);"
											..."CREATE INDEX `idx_both1` ON `clients_mute` (`client_steamid`, `target_steamid`);"
											..."CREATE INDEX `idx_both2` ON `groups_mute` (`client_steamid`, `group_filter`);");
											
		T_mysqlTables.AddQuery(query0);
		
		g_hDB.Execute(T_mysqlTables, DB_mysqlTablesOnSuccess, DB_mysqlTablesOnError, _, DBPrio_High);
	} else if (strcmp(driver, "sqlite", false) == 0) {
		g_bSQLLite = true;
		Transaction T_sqliteTables = SQL_CreateTransaction();
		
		char query0[1024];		
		g_hDB.Format(query0, sizeof(query0), "CREATE TABLE IF NOT EXISTS `clients_data`("
												... "`id` INTEGER PRIMARY KEY AUTOINCREMENT," 
												... "`client_steamid` INTEGER NOT NULL," 
												... "`mute_type` int(2) NOT NULL,"
												... "`mute_duration` int(2) NOT NULL,"
												... "UNIQUE(`client_steamid`))");
																						
		T_sqliteTables.AddQuery(query0);
		
		char query1[1024];		
		g_hDB.Format(query1, sizeof(query1), "CREATE TABLE IF NOT EXISTS `clients_mute`("
												... "`id` INTEGER PRIMARY KEY AUTOINCREMENT," 
												... "`client_name` varchar(32) NOT NULL," 
												... "`client_steamid` INTEGER NOT NULL," 
												... "`target_name` varchar(32) NOT NULL," 
												... "`target_steamid` INTEGER NOT NULL," 
												... "`text_chat` int(2) NOT NULL,"
												... "`voice_chat` int(2) NOT NULL,"
												... "UNIQUE(`client_steamid`, `target_steamid`))");
																						
		T_sqliteTables.AddQuery(query1);
	
		char query2[1024];	
		g_hDB.Format(query2, sizeof(query2), "CREATE TABLE IF NOT EXISTS `groups_mute`("
												... "`id` INTEGER PRIMARY KEY AUTOINCREMENT," 
												... "`client_name` varchar(32) NOT NULL," 
												... "`client_steamid` INTEGER NOT NULL," 
												... "`group_name` varchar(32) NOT NULL," 
												... "`group_filter` varchar(20) NOT NULL,"
												... "`text_chat` int(2) NOT NULL,"
												... "`voice_chat` int(2) NOT NULL,"
												... "UNIQUE(`client_steamid`, `group_filter`))"); 
												
		T_sqliteTables.AddQuery(query2);
		g_hDB.Execute(T_sqliteTables, DB_sqliteTablesOnSuccess, DB_sqliteTablesOnError, _, DBPrio_High);
	} else {
		#if defined DEBUG
			LogError("[Self-Mute] Couldn't create tables for an unknown driver");
		#endif
		return;
	}
}

// Transaction callbacks for tables:
public void DB_mysqlTablesOnSuccess(Database database, any data, int queries, Handle[] results, any[] queryData) {
	LogMessage("[Self-Mute] Database is now ready! (MYSQL)");
	return;
}

public void DB_mysqlTablesOnError(Database database, any data, int queries, const char[] error, int failIndex, any[] queryData)
{
	#if defined DEBUG
		LogError("[Self-Mute] Couldn't create tables for MYSQL, error: %s", error);
	#endif
	return;
}

public void DB_sqliteTablesOnSuccess(Database database, any data, int queries, Handle[] results, any[] queryData)
{
	LogMessage("[Self-Mute] Database is now ready! (SQLITE)");
	return;
}

public void DB_sqliteTablesOnError(Database database, any data, int queries, const char[] error, int failIndex, any[] queryData)
{
	#if defined DEBUG
		LogError("[Self-Mute] Couldn't create tables for SQLITE, error: %s", error);
	#endif
	return;
}

/* Connections Check */
public void OnClientConnected(int client) {
	if (!IsClientSourceTV(client)) {
		return;
	}
	
	char clientName[32];
	if (!GetClientName(client, clientName, sizeof(clientName))) {
		strcopy(clientName, sizeof(clientName), "Source TV");
	}
	
	g_PlayerData[client].Setup(clientName, "Console", MuteType_None, MuteDuration_Permanent); // whatever values but name and steamid are the important
}

public void OnClientPostAdminCheck(int client) {
	if (g_hDB == null)
		return;

	if (IsFakeClient(client)) {
		return;
	}
	
	/* Get Client Data */
	int steamID = GetSteamAccountID(client);
	if (!steamID) {
		return;
	}
	
	char steamIDStr[20];
	IntToString(steamID, steamIDStr, sizeof(steamIDStr));
	
	char clientName[MAX_NAME_LENGTH];
	if (!GetClientName(client, clientName, sizeof(clientName))) {
		return;
	}
	
	MuteType muteType = view_as<MuteType>(g_cvDefaultMuteTypeSettings.IntValue);
	MuteDuration muteDuration = view_as<MuteDuration>(g_cvDefaultMuteDurationSettings.IntValue);
	
	g_PlayerData[client].Setup(clientName, steamIDStr, muteType, muteDuration);
	
	char query[1024];
	FormatEx(query, sizeof(query), "SELECT `mute_type`,`mute_duration` FROM `clients_data` WHERE `client_steamid`=%d", steamID);
	g_hDB.Query(DB_OnGetClientData, query, GetClientUserId(client));
}

void DB_OnGetClientData(Database db, DBResultSet results, const char[] error, int userid) {
	if (error[0]) {
		LogError("[Self-Mute] Could not revert client data, error: %s", error);
		return;
	}
	
	int client = GetClientOfUserId(userid);
	if (!client) {
		return;
	}
	
	int steamID = StringToInt(g_PlayerData[client].steamID);
	
	if (results.FetchRow()) {
		g_PlayerData[client].addedToDB = true;
		
		g_PlayerData[client].muteType = view_as<MuteType>(results.FetchInt(0));
		g_PlayerData[client].muteDuration = view_as<MuteDuration>(results.FetchInt(1));
	}
		
	/* Now get mute list duh, get both the client as a client and as a target */
	/* We will select 5 fieds of each table, though not all fields are required, NULL will be given */
	/* 0. `target_name`	-> Target (player) name OR the group name (string) */
	/* 1. `tar_id`			-> Target (player) steamID (int) */
	/* 2. `grp_id`			-> Group Filter char (string) */
	/* 3. `text_chat`		-> Target (player & group) Text Chat Status (tinyint or int(2)) */
	/* 4. `voice_chat`		-> Target (player & group) Voice Chat Status (tinyint or int(2)) */
	char query[1024];
	FormatEx(query, sizeof(query), 
					"SELECT `target_name` AS `tar_name`, `target_steamid` AS `tar_id`, NULL AS `grp_id`,"
				...	"`text_chat` AS `text_chat`, `voice_chat` AS `voice_chat` "
				... "FROM `clients_mute` WHERE `client_steamid`=%d "
				... "UNION ALL "
				... "SELECT `group_name` AS `tar_name`, NULL AS `tar_id`, `group_filter` AS `grp_id`,"
				... "`text_chat` AS `text_chat`, `voice_chat` AS `voice_chat` "
				... "FROM `groups_mute` WHERE `client_steamid`=%d "
				... "UNION ALL "
				... "SELECT NULL AS `tar_name`, `client_steamid` AS `tar_id`, NULL AS `grp_id`,"
				... "`text_chat` AS `text_chat`, `voice_chat` AS `voice_chat` "
				... "FROM `clients_mute` WHERE `target_steamid`=%d",
				steamID, steamID, steamID
	);
	
	g_hDB.Query(DB_OnGetClientTargets, query, userid);
}

void DB_OnGetClientTargets(Database db, DBResultSet results, const char[] error, int userid) {
	if (!results || error[0]) {
		LogError("[Self-Mute] Error while getting client's client/target mutes, error: %s", error);
		return;
	}
	
	if (!results.RowCount) {
		return;
	}
	
	int desiredClient = GetClientOfUserId(userid);
	if (!desiredClient) {
		return;
	}
	
	PrintToChat("DB_OnGetClientTargets callback");
	
	while(results.FetchRow()) {
		PrintToChatAll("Found row");
		
		char targetName[32];
		results.FetchString(0, targetName, sizeof(targetName));
		
		bool isGroup = results.IsFieldNull(1);
		
		bool text = view_as<bool>(results.FetchInt(3));
		bool voice = view_as<bool>(results.FetchInt(4));
		MuteType muteType = GetMuteType(text, voice);
		
		if (!isGroup) {
			PrintToChatAll("Mute is NOT group");
			char steamIDStr[20];
			IntToString(results.FetchInt(1), steamIDStr, sizeof(steamIDStr));
			
			PrintToChatAll("Mute Data: \nclient: %N\ntarget steamID: %s", desiredClient, steamIDStr);
			int target = GetClientBySteamID(steamIDStr);
			if (target == -1) {
				PrintToChatAll("Target is -1, stemaID: %s", steamIDStr);
				continue;
			}
			
			if (!targetName[0]) {
				ApplySelfMute(target, desiredClient, muteType);
			} else {
				SelfMute myMute;
				myMute.AddMute(targetName, steamIDStr, muteType, MuteTarget_Client);
				g_PlayerData[desiredClient].mutesList.PushArray(myMute);
				ApplySelfMute(desiredClient, target, muteType);
				PrintToChatAll("Applying selfmute...");
			}
		} else {
			PrintToChatAll("Mute is GROUP");
			char groupFilter[20];
			results.FetchString(2, groupFilter, sizeof(groupFilter));
			
			SelfMute myMute;
			myMute.AddMute(targetName, groupFilter, muteType, MuteTarget_Group);
			g_PlayerData[desiredClient].mutesList.PushArray(myMute);
			
			ApplySelfMuteGroup(desiredClient, groupFilter, muteType);
		}
	}
}

public void OnClientDisconnect(int client) {
	if (IsFakeClient(client)) {
		return;
	}
	
	g_PlayerData[client].Reset();
	
	for (int i = 1; i <= MaxClients; i++) {
		g_bClientText[i][client] = false;
		g_bClientVoice[i][client] = false;
		g_bClientText[client][i] = false;
		g_bClientVoice[client][i] = false;
		
		SetIgnored(i, client, false);
		SetIgnored(client, i, false);
		
		if (IsClientConnected(i)) {
			SetListenOverride(i, client, Listen_Yes);
			SetListenOverride(client, i, Listen_Yes);
		}
	}
	
	UpdateIgnored();
}

public void CookieMenu_Handler(int client, CookieMenuAction action, any info, char[] buffer, int maxlen)
{
	if (action == CookieMenuAction_DisplayOption) {
		Format(buffer, maxlen, "Self-Mute Settings");
	}
	
	if (action == CookieMenuAction_SelectOption) {
		ShowCookiesMenu(client);
	}
}

void UpdateIgnored() {
	if (g_Plugin_ccc)
		CCC_UpdateIgnoredArray(g_Ignored);
}

bool GetIgnored(int client, int target) {
	return g_Ignored[(client * (MAXPLAYERS + 1) + target)];
}

void SetIgnored(int client, int target, bool ignored) {
	g_Ignored[(client * (MAXPLAYERS + 1) + target)] = ignored;
}

void ApplySelfMute(int client, int target, MuteType muteType) {
	if (!g_cvMuteAdmins.BoolValue && IsClientAdmin(target)) {
		CPrintToChat(client, "You cannot self-mute an admin!");
		return;
	}
	
	switch(muteType) {
		case MuteType_Text: {
			SetIgnored(client, target, true);
			UpdateIgnored();
			g_bClientText[client][target] = true;
		}
		
		case MuteType_Voice: {
			SetListenOverride(client, target, Listen_No);
			g_bClientVoice[client][target] = true;
		}
		
		case MuteType_All: {
			SetIgnored(client, target, true);
			UpdateIgnored();
			SetListenOverride(client, target, Listen_No);
			
			g_bClientText[client][target] = true;
			g_bClientVoice[client][target] = true;
		}
	}
}

void ApplySelfMuteGroup(int client, const char[] groupFilterC, MuteType muteType) {
	GroupFilter groupFilter = GetGroupFilterByChar(groupFilterC);
	int groupFilterIndex = view_as<int>(groupFilter);
	
	switch(muteType) {
		case MuteType_Text: {
			g_bClientGroupText[client][groupFilterIndex] = true;
		}
		
		case MuteType_Voice: {
			g_bClientGroupVoice[client][groupFilterIndex] = true;
		}
		
		case MuteType_All: {
			g_bClientGroupText[client][groupFilterIndex] = true;
			g_bClientGroupVoice[client][groupFilterIndex] = true;
		}
	}
	
	UpdateSelfMuteGroup(client, groupFilter);
}

void ApplySelfUnMute(int client, int target) {
	if (g_bClientText[client][target]) {
		SetIgnored(client, target, false);
		UpdateIgnored();
		g_bClientText[client][target] = false;
	}
	
	if (g_bClientVoice[client][target]) {
		SetListenOverride(client, target, Listen_Yes);
		g_bClientVoice[client][target] = false;
	}
	
	DeleteMuteFromDatabase(client, g_PlayerData[target].steamID, MuteTarget_Client);
}

void ApplySelfUnMuteGroup(int client, GroupFilter groupFilter) {
	int target = view_as<int>(groupFilter);
	if (g_bClientGroupText[client][target]) {
		for (int i = 1; i <= MaxClients; i++) {
			if (!IsClientInGame(i) || g_bClientText[client][i] || !IsClientInGroup(i, groupFilter)) {
				continue;
			}	
			
			SetIgnored(client, i, false);
		}
		
		UpdateIgnored();
	}
	
	if (g_bClientGroupVoice[client][target]) {
		for (int i = 1; i <= MaxClients; i++) {
			if (!IsClientInGame(i) || g_bClientVoice[client][i] || !IsClientInGroup(i, groupFilter)) {
				continue;
			}	
			
			SetListenOverride(client, i, Listen_Yes);
		}
	}
	
	g_bClientGroupText[client][target] = false;
	g_bClientGroupVoice[client][target] = false;
	
	SelfUnMutePreviousGroup(client);
	
	for (int i = 0; i < view_as<int>(GROUP_MAX_NUM); i++) {
		if (g_bClientGroupText[client][i] || g_bClientGroupVoice[client][i]) {
			UpdateSelfMuteGroup(client, view_as<GroupFilter>(i));
		}
	}
	
	DeleteMuteFromDatabase(client, g_sGroupsFilters[target], MuteTarget_Group);
}

void DeleteMuteFromDatabase(int client, char[] id, MuteTarget muteTarget) {
	if (!IsThisMutedPerma(client, id, muteTarget, true)) {
		return;
	}
	
	if (muteTarget == MuteTarget_Group) {
		char tempId[20];
		strcopy(tempId, sizeof(tempId), id);
		FormatEx(id, 20, "'%s'", tempId);
	}
	
	char query[124];
	FormatEx(query, sizeof(query), "DELETE FROM `%s` WHERE `client_steamid`=%d AND `%s`=%s", 
	(muteTarget == MuteTarget_Client) ? "clients_mute" : "groups_mute",
	StringToInt(g_PlayerData[client].steamID),
	(muteTarget == MuteTarget_Client) ? "target_steamid" : "group_filter",
	id);
	
	g_hDB.Query(DB_OnRemove, query);
}

void DB_OnRemove(Database db, DBResultSet results, const char[] error, any data) {
	if (!results || error[0]) {
		LogError("[Self-Mute] Could not delete mute from database, error: %s", error);
	}
}

bool IsThisMutedPerma(int client, const char[] id, MuteTarget muteTarget, bool remove = false) {
	if (!g_PlayerData[client].mutesList) {
		return false;
	}
	
	for (int i = 0; i < g_PlayerData[client].mutesList.Length; i++) {
		SelfMute selfMute;
		g_PlayerData[client].mutesList.GetArray(i, selfMute, sizeof(selfMute));
		if (strcmp(id, selfMute.id) == 0 && muteTarget == selfMute.muteTarget) {
			if (remove) {
				g_PlayerData[client].mutesList.Erase(i);
			}
			
			return true;
		}
	}
	
	return false;
}

void SaveSelfMuteClient(int client, int target) {
	char clientName[sizeof(PlayerData::name) * 2 + 1];
	char targetName[sizeof(PlayerData::name) * 2 + 1];
	
	if (!g_hDB.Escape(g_PlayerData[client].name, clientName, sizeof(clientName))
		|| !g_hDB.Escape(g_PlayerData[target].name, targetName, sizeof(targetName))) {
		return;
	}
	
	int clientSteamID = StringToInt(g_PlayerData[client].steamID);
	int targetSteamID = StringToInt(g_PlayerData[target].steamID);
	
	if (!clientSteamID || targetSteamID == 0) {
		return;
	}
	
	char query[512];
	if (!g_bSQLLite) {
		FormatEx(query, sizeof(query), "INSERT INTO `clients_mute` (`client_name`, `client_steamid`, `target_name`, `target_steamid`,"
										... "`text_chat`, `voice_chat`) VALUES ('%s', %d, '%s', %d, %d, %d)"
										... "ON DUPLICATE KEY UPDATE `client_name`='%s', `target_name`='%s', `text_chat`=%d, `voice_chat`=%d",
										clientName, clientSteamID, targetName,
										targetSteamID, view_as<int>(g_bClientText[client][target]),
										view_as<int>(g_bClientVoice[client][target]), 
										clientName, targetName,
										view_as<int>(g_bClientText[client][target]),
										view_as<int>(g_bClientVoice[client][target]));
	} else {
		FormatEx(query, sizeof(query), "REPLACE INTO `clients_mute` (`client_name`, `client_steamid`, `target_name`, `target_steamid`,"
										... "`text_chat`, `voice_chat`) VALUES ('%s', %d, '%s', %d, %d, %d)",
										clientName, clientSteamID, targetName,
										targetSteamID, view_as<int>(g_bClientText[client][target]),
										view_as<int>(g_bClientVoice[client][target]));
	}
									
	g_hDB.Query(DB_OnInsertData, query);
	
	IsThisMutedPerma(client, g_PlayerData[target].steamID, MuteTarget_Client, true);
	MuteType muteType = GetMuteType(g_bClientText[client][target], g_bClientVoice[client][target]);
	
	SelfMute myMute;
	myMute.AddMute(g_PlayerData[target].name, g_PlayerData[target].steamID, muteType, MuteTarget_Client);
	g_PlayerData[client].mutesList.PushArray(myMute);
}

void SaveSelfMuteGroup(int client, GroupFilter groupFilter) {
	char clientName[sizeof(PlayerData::name) * 2 + 1];
	char groupName[32 * 2 + 1];
	char groupFilterC[20 * 2 + 1];
	
	if (!g_hDB.Escape(g_PlayerData[client].name, clientName, sizeof(clientName))
		|| !g_hDB.Escape(g_sGroupsNames[view_as<int>(groupFilter)], groupName, sizeof(groupName))
		|| !g_hDB.Escape(g_sGroupsFilters[view_as<int>(groupFilter)], groupFilterC, sizeof(groupFilterC))) {
		return;
	}
	
	int clientSteamID = StringToInt(g_PlayerData[client].steamID);
	if (!clientSteamID) {
		return;
	}
	
	char query[512];
	if (!g_bSQLLite) {
		FormatEx(query, sizeof(query), "INSERT INTO `groups_mute` (`client_name`, `client_steamid`, `group_name`, `group_filter`,"
										... "`text_chat`, `voice_chat`) VALUES ('%s', %d, '%s', '%s', %d, %d)"
										... "ON DUPLICATE KEY UPDATE `client_name`='%s', `text_chat`=%d, `voice_chat`=%d",
										clientName, clientSteamID, groupName,
										groupFilterC, view_as<int>(g_bClientGroupText[client][view_as<int>(groupFilter)]),
										view_as<int>(g_bClientGroupVoice[client][view_as<int>(groupFilter)]), 
										clientName,
										view_as<int>(g_bClientGroupText[client][view_as<int>(groupFilter)]),
										view_as<int>(g_bClientGroupVoice[client][view_as<int>(groupFilter)]));
	} else {
		FormatEx(query, sizeof(query), "REPLACE INTO `groups_mute` (`client_name`, `client_steamid`, `group_name`, `group_filter`,"
										... "`text_chat`, `voice_chat`) VALUES ('%s', %d, '%s', '%s', %d, %d)",
										clientName, clientSteamID, groupName,
										groupFilterC, view_as<int>(g_bClientGroupText[client][view_as<int>(groupFilter)]),
										view_as<int>(g_bClientGroupVoice[client][view_as<int>(groupFilter)]));
	}
									
	g_hDB.Query(DB_OnInsertData, query);
	
	IsThisMutedPerma(client, g_sGroupsFilters[view_as<int>(groupFilter)], MuteTarget_Group, true);
	MuteType muteType = GetMuteType(g_bClientGroupText[client][view_as<int>(groupFilter)], g_bClientGroupVoice[client][view_as<int>(groupFilter)]);
	
	SelfMute myMute;
	myMute.AddMute(g_sGroupsNames[view_as<int>(groupFilter)], g_sGroupsFilters[view_as<int>(groupFilter)], muteType, MuteTarget_Group);
	g_PlayerData[client].mutesList.PushArray(myMute);
}

void DB_OnInsertData(Database db, DBResultSet results, const char[] error, any data) {
	if (!results || error[0]) {
		LogError("[Self-Mute] Could not insert data into the database, error: %s", error);
	}
}

void DB_UpdateClientData(int client, int mode) {
	if (g_hDB == null) {
		return;
	}
	
	int steamID = StringToInt(g_PlayerData[client].steamID);
	if (!steamID) {
		return;
	}
		
	if (!g_PlayerData[client].addedToDB) {
		char query[120];
		if (!g_bSQLLite) {
			FormatEx(query, sizeof(query), "INSERT INTO `clients_data` ("
											... "`client_steamid`, `mute_type`, `mute_duration`)"
											... "VALUES (%d, %d, %d) "
											... "ON DUPLICATE KEY UPDATE `mute_type`=%d, `mute_duration`=%d", 
											steamID, 
											view_as<int>(g_PlayerData[client].muteType), 
											view_as<int>(g_PlayerData[client].muteDuration),
											view_as<int>(g_PlayerData[client].muteType), 
											view_as<int>(g_PlayerData[client].muteDuration));
		} else {
			FormatEx(query, sizeof(query), "REPLACE INTO `clients_data` ("
											... "`client_steamid`, `mute_type`, `mute_duration`)"
											... "VALUES (%d, %d, %d)",
											steamID, 
											view_as<int>(g_PlayerData[client].muteType), 
											view_as<int>(g_PlayerData[client].muteDuration));
		}
		
		g_hDB.Query(DB_OnAddData, query);
		
		g_PlayerData[client].addedToDB = true;
		
		DataPack pack = new DataPack();
		pack.WriteCell(GetClientUserId(client));
		pack.WriteCell(mode);
		CreateTimer(1.0, UpdateClientData_Timer, pack);
		return;
	}
	
	if (g_PlayerData[client].steamID[0]) {
		/* Update client data in sql */
		char query[256];
		FormatEx(query, sizeof(query), "UPDATE `clients_data` SET `%s`=%d WHERE `client_steamid`=%d",
										(mode == 0) ? "mute_type" : "mute_duration", 
										(mode == 0) ? view_as<int>(g_PlayerData[client].muteType) : view_as<int>(g_PlayerData[client].muteDuration),
										steamID);
										
		g_hDB.Query(DB_OnUpdateData, query);
	}
}

Action UpdateClientData_Timer(Handle timer, DataPack pack) {
	pack.Reset();
	
	int client = GetClientOfUserId(pack.ReadCell());
	if (!client) {
		delete pack;
		return Plugin_Stop;
	}
	
	int mode = pack.ReadCell();
	DB_UpdateClientData(client, mode);
	
	delete pack;
	return Plugin_Stop;
}

void DB_OnAddData(Database db, DBResultSet results, const char[] error, any data) {
	if (error[0]) {
		LogError("[Self-Mute] Error while inserting client's data, error: %s", error);
		return;
	}
}

void DB_OnUpdateData(Database db, DBResultSet results, const char[] error, any data) {
	if (error[0]) {
		LogError("[SM] Error while updating client data, error: %s", error);
	}
}

bool IsClientAdmin(int client) {
	return CheckCommandAccess(client, "sm_admin", ADMFLAG_GENERIC, true);
}

MuteType GetMuteType(bool text, bool voice) {
	if (text && voice) {
		return MuteType_All;
	} else if (text && !voice) {
		return MuteType_Text;
	} else if (!text && voice) {
		return MuteType_Voice;
	}
	
	return MuteType_None;
}

GroupFilter GetGroupFilterByChar(const char[] groupFilterC) {
	for (int i = 0; i < sizeof(g_sGroupsFilters); i++) {
		if (strcmp(g_sGroupsFilters[i], groupFilterC) == 0) {
			return view_as<GroupFilter>(i);
		}
	}
	
	return GROUP_ALL;
}

void SelfUnMutePreviousGroup(int client) {
	bool shouldUpdateIgnored;
	for (int i = 1; i <= MaxClients; i++) {
		if (i == client) {
			continue;
		}
		
		if (!IsClientConnected(i)) {
			continue;
		}
		
		if (GetIgnored(client, i) && !g_bClientText[client][i]) {
			shouldUpdateIgnored = true;
			SetIgnored(client, i, false);
		}
		
		if (GetListenOverride(client, i) == Listen_No && !g_bClientVoice[client][i]) {
			SetListenOverride(client, i, Listen_Yes);
		}
	}
	
	if (shouldUpdateIgnored) {
		UpdateIgnored();
	}
}

void UpdateSelfMuteGroup(int client, GroupFilter groupFilter) {
	bool shouldUpdateIgnored;
	for (int i = 1; i <= MaxClients; i++) {
		if (i == client) {
			continue;
		}
		
		if (!IsClientConnected(i)) {
			continue;
		}
		
		if (!g_cvMuteAdmins.BoolValue && IsClientAdmin(i)) {
			continue;
		}
		
		if (!IsClientInGroup(i, groupFilter)) {
			continue;
		}
		
		if (g_bClientGroupText[client][view_as<int>(groupFilter)]) {
			shouldUpdateIgnored = true;
			SetIgnored(client, i, true);
		}
		
		if (g_bClientGroupVoice[client][view_as<int>(groupFilter)]) {
			SetListenOverride(client, i, Listen_No);
		}
	}
	
	if (shouldUpdateIgnored) {
		UpdateIgnored();
	}
}

bool IsClientInGroup(int client, GroupFilter groupFilter) {
	if (!client) {
		return false;
	}

	if (!IsClientInGame(client)) {
		return false;
	}
			
	int team = GetClientTeam(client);
	switch(groupFilter) {
		case GROUP_ALL: {
			return true;
		}
		
		case GROUP_CTS: {
			if (g_Plugin_zombiereloaded) {
				if (!IsPlayerAlive(client) || !ZR_IsClientHuman(client)) {
					return false;
				}
			} else {
				if (team != CS_TEAM_CT) {
					return false;
				}
			}
			
			return true;
		}
	
		case GROUP_TS: {
			if (g_Plugin_zombiereloaded) {
				if (!IsPlayerAlive(client) || !ZR_IsClientZombie(client)) {
					return false;
				}
			} else {
				if (team != CS_TEAM_T) {
					return false;
				}
			}
			
			return true;
		}
		
		case GROUP_SPECTATORS: {
			if (team != CS_TEAM_SPECTATOR && team != CS_TEAM_NONE) {
				return false;
			}
			
			return true;
		}
	}

	return true;
}

int GetClientBySteamID(const char[] steamID) {
	for (int i = 1; i <= MaxClients; i++) {
		if (!IsClientInGame(i)) {
			continue;
		}

		if (IsClientSourceTV(i) && strcmp("Console", steamID) == 0) {
			return i;
		}
		
		if (IsFakeClient(i)) {
			continue;
		}
		
		if (strcmp(g_PlayerData[i].steamID, steamID, false) == 0) {
			return i;
		}
	}

	return -1;
}

/* Thanks to Botox Original Self-Mute plugin for the radio commands part */
int g_MsgDest;
int g_MsgClient;
char g_MsgName[256];
char g_MsgParam1[256];
char g_MsgParam2[256];
char g_MsgParam3[256];
char g_MsgParam4[256];
char g_MsgRadioSound[256];
int g_MsgPlayersNum;
int g_MsgPlayers[MAXPLAYERS + 1];

public Action Hook_UserMessageRadioText(UserMsg msg_id, Handle bf, const int[] players, int playersNum, bool reliable, bool init) {
	if (g_bIsProtoBuf) {
		g_MsgDest = PbReadInt(bf, "msg_dst");
		g_MsgClient = PbReadInt(bf, "client");
		PbReadString(bf, "msg_name", g_MsgName, sizeof(g_MsgName));
		PbReadString(bf, "params", g_MsgParam1, sizeof(g_MsgParam1), 0);
		PbReadString(bf, "params", g_MsgParam2, sizeof(g_MsgParam2), 1);
		PbReadString(bf, "params", g_MsgParam3, sizeof(g_MsgParam3), 2);
		PbReadString(bf, "params", g_MsgParam4, sizeof(g_MsgParam4), 3);
	}
	else {
		g_MsgDest = BfReadByte(bf);
		g_MsgClient = BfReadByte(bf);
		BfReadString(bf, g_MsgName, sizeof(g_MsgName), false);
		BfReadString(bf, g_MsgParam1, sizeof(g_MsgParam1), false);
		BfReadString(bf, g_MsgParam2, sizeof(g_MsgParam2), false);
		BfReadString(bf, g_MsgParam3, sizeof(g_MsgParam3), false);
		BfReadString(bf, g_MsgParam4, sizeof(g_MsgParam4), false);
	}

	// Check which clients need to be excluded.
	g_MsgPlayersNum = 0;
	for (int i = 0; i < playersNum; i++) {
		int client = players[i];
		if (!(g_bClientText[client][g_MsgClient] || g_bClientVoice[client][g_MsgClient]))
			g_MsgPlayers[g_MsgPlayersNum++] = client;
	}

	// No clients were excluded.
	if (g_MsgPlayersNum == playersNum) {
		g_MsgClient = -1;
		return Plugin_Continue;
	} else if (g_MsgPlayersNum == 0) { // All clients were excluded and there is no need to broadcast.
		g_MsgClient = -2;
		return Plugin_Handled;
	}

	return Plugin_Handled;
}

public Action Hook_UserMessageSendAudio(UserMsg msg_id, Handle bf, const int[] players, int playersNum, bool reliable, bool init) {
	if (g_MsgClient == -1) {
		return Plugin_Continue;
	} else if (g_MsgClient == -2) {
		return Plugin_Handled;
	}

	if (g_bIsProtoBuf) {
		PbReadString(bf, "radio_sound", g_MsgRadioSound, sizeof(g_MsgRadioSound));
	} else {
		BfReadString(bf, g_MsgRadioSound, sizeof(g_MsgRadioSound), false);
	}
	
	if (strcmp(g_MsgRadioSound, "radio.locknload") == 0) {
		return Plugin_Continue;
	}

	DataPack pack = new DataPack();
	pack.WriteCell(g_MsgDest);
	pack.WriteCell(g_MsgClient);
	pack.WriteString(g_MsgName);
	pack.WriteString(g_MsgParam1);
	pack.WriteString(g_MsgParam2);
	pack.WriteString(g_MsgParam3);
	pack.WriteString(g_MsgParam4);
	pack.WriteString(g_MsgRadioSound);
	pack.WriteCell(g_MsgPlayersNum);

	for (int i = 0; i < g_MsgPlayersNum; i++) {
		pack.WriteCell(g_MsgPlayers[i]);
	}
	
	RequestFrame(OnPlayerRadio, pack);

	return Plugin_Handled;
}

public void OnPlayerRadio(DataPack pack)
{
	pack.Reset();
	g_MsgDest = pack.ReadCell();
	g_MsgClient = pack.ReadCell();
	pack.ReadString(g_MsgName, sizeof(g_MsgName));
	pack.ReadString(g_MsgParam1, sizeof(g_MsgParam1));
	pack.ReadString(g_MsgParam2, sizeof(g_MsgParam2));
	pack.ReadString(g_MsgParam3, sizeof(g_MsgParam3));
	pack.ReadString(g_MsgParam4, sizeof(g_MsgParam4));
	pack.ReadString(g_MsgRadioSound, sizeof(g_MsgRadioSound));
	g_MsgPlayersNum = pack.ReadCell();

	int playersNum = 0;
	for (int i = 0; i < g_MsgPlayersNum; i++) {
		int client_ = pack.ReadCell();
		if (IsClientInGame(client_)) {
			g_MsgPlayers[playersNum++] = client_;
		}
	}
	
	delete pack;

	Handle RadioText = StartMessage("RadioText", g_MsgPlayers, playersNum, USERMSG_RELIABLE);
	if (g_bIsProtoBuf) {
		PbSetInt(RadioText, "msg_dst", g_MsgDest);
		PbSetInt(RadioText, "client", g_MsgClient);
		PbSetString(RadioText, "msg_name", g_MsgName);
		PbSetString(RadioText, "params", g_MsgParam1, 0);
		PbSetString(RadioText, "params", g_MsgParam2, 1);
		PbSetString(RadioText, "params", g_MsgParam3, 2);
		PbSetString(RadioText, "params", g_MsgParam4, 3);
	} else {
		BfWriteByte(RadioText, g_MsgDest);
		BfWriteByte(RadioText, g_MsgClient);
		BfWriteString(RadioText, g_MsgName);
		BfWriteString(RadioText, g_MsgParam1);
		BfWriteString(RadioText, g_MsgParam2);
		BfWriteString(RadioText, g_MsgParam3);
		BfWriteString(RadioText, g_MsgParam4);
	}
	
	EndMessage();

	Handle SendAudio = StartMessage("SendAudio", g_MsgPlayers, playersNum, USERMSG_RELIABLE);
	if (g_bIsProtoBuf) {
		PbSetString(SendAudio, "radio_sound", g_MsgRadioSound);
	} else {
		BfWriteString(SendAudio, g_MsgRadioSound);
	}
	EndMessage();
}
