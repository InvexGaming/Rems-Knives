#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <cstrike>
#include <clientprefs>
#include <csgoitems>
#include <PTaH>
#include <colors_csgo_v2>

#pragma semicolon 1
#pragma newdecls required

/*********************************
 *  Plugin Information
 *********************************/
#define PLUGIN_VERSION "1.04"

public Plugin myinfo =
{
  name = "Rems Knives (!rk)",
  author = "Invex | Byte",
  description = "Provides official CSGO knives to players.",
  version = PLUGIN_VERSION,
  url = "http://www.invexgaming.com.au"
};

/*********************************
 *  Definitions
 *********************************/
#define CHAT_TAG_PREFIX "[{lime}RK{default}] "

//Hardcoded action values
//Should be a high index > num of knives
#define _ACTIONBASE 1000
#define DEFAULT_KNIFE _ACTIONBASE
#define RANDOM_KNIFE _ACTIONBASE+1
#define SEARCH_KNIFE _ACTIONBASE+2

//Knife indexes and item defs
#define INVALID_KNIFE_INDEX -1
#define DEFAULT_KNIFE_INDEX_T 0
#define DEFAULT_KNIFE_INDEX_CT 1
#define DEFAULT_KNIFE_DEFINDEX_T 59
#define DEFAULT_KNIFE_DEFINDEX_CT 42

#define MIN_CONFIG_INDEX 2 //Minimum index for knives after hardcoded defaults
#define MAX_TARGET_TEAMS 2

//Menu
#define MAX_MENU_OPTIONS 6
#define MAINMENU_SELECTTEAMTARGET 0
#define MAINMENU_SELECTKNIFE 1

/*********************************
 *  Enumerations
 *********************************/
enum TargetTeam
{
  TargetTeam_CurrentTeam,
  TargetTeam_T,
  TargetTeam_CT,
  TargetTeam_Both,
}

/*********************************
 *  Globals
 *********************************/

//Convars
ConVar g_Cvar_VipFlag = null;
ConVar g_Cvar_Instant = null;

//Cookies
Handle g_TargetTeamCookie = null;
Handle g_KnifeTCookie = null;
Handle g_KnifeCTCookie = null;

//Main
ArrayList g_KnivesDefIndexes;
bool g_AreKnivesLoaded = false;
int g_ClientKnives[MAXPLAYERS+1][4]; //can be indexed directly with team for T and CT options
TargetTeam g_ClientTargetTeam[MAXPLAYERS+1] = {TargetTeam_CurrentTeam, ...};
bool g_WaitingForSayInput[MAXPLAYERS+1] = {false, ...};

//Forwards
bool g_IsPostAdminCheck[MAXPLAYERS+1] = {false, ...}; //for OnClientPostAdminCheckAndCookiesCached

//Menu
Menu g_MainMenu = null;
Menu g_TargetTeamMenu = null;
Menu g_KnivesMenu = null;

//Lateload
bool g_LateLoaded = false;

/*********************************
 *  Forwards
 *********************************/

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
  g_LateLoaded = late;

  return APLRes_Success;
}

public void OnPluginStart()
{
  //Translations
  LoadTranslations("rk.phrases");

  //Setup cookies
  g_TargetTeamCookie = RegClientCookie("RemsKnives_TargetTeam", "Team that is being targetted", CookieAccess_Private);
  g_KnifeTCookie = RegClientCookie("RemsKnives_KnifeT", "Knife selection for T side", CookieAccess_Private);
  g_KnifeCTCookie = RegClientCookie("RemsKnives_KnifeCT", "Knife selection for CT side", CookieAccess_Private);

  //ConVars
  g_Cvar_VipFlag = CreateConVar("sm_rk_vipflag", "", "Flag to identify VIP players. Leave blank for open access.");
  g_Cvar_Instant = CreateConVar("sm_rk_instant", "1", "Should the player receive the knife instantly (if alive)");

  AutoExecConfig(true, "rk");

  //Commands
  RegConsoleCmd("sm_rk", Command_Knife, "Select a knife via menu or quick search");
  RegConsoleCmd("sm_knife", Command_Knife, "Select a knife via menu or quick search");
  RegConsoleCmd("sm_knifes", Command_Knife, "Select a knife via menu or quick search");
  RegConsoleCmd("sm_knive", Command_Knife, "Select a knife via menu or quick search");
  RegConsoleCmd("sm_knives", Command_Knife, "Select a knife via menu or quick search");

  //Initilise 2D Array
  for (int i = 0; i < sizeof(g_ClientKnives); ++i) {
    g_ClientKnives[i][CS_TEAM_T] = DEFAULT_KNIFE_INDEX_T;
    g_ClientKnives[i][CS_TEAM_CT] = DEFAULT_KNIFE_INDEX_CT;
  }

  //Late load
  if (g_LateLoaded) {
    for (int i = 1; i <= MaxClients; ++i) {
      //This is a comprimise check which ensures OnClientPreAdminCheck is reached
      //There is no actual way to check PostAdminCheck status in a late load
      g_IsPostAdminCheck[i] = IsClientInGame(i) && IsClientAuthorized(i);

      if (IsClientInGame(i)) {
        OnClientPutInServer(i);

        if (!IsFakeClient(i) && g_IsPostAdminCheck[i] && AreClientCookiesCached(i))
          OnClientPostAdminCheckAndCookiesCached(i);
      }
    }
    
    //Late load item sync
    if (CSGOItems_AreItemsSynced())
      CSGOItems_OnItemsSynced();

    g_LateLoaded = false;
  }

  //Hooks
  PTaH(PTaH_GiveNamedItem, Hook, GiveNamedItem);
  PTaH(PTaH_GiveNamedItemPre, Hook, GiveNamedItemPre);
}

//Monitor chat to capture commands
public Action OnClientSayCommand(int client, const char[] command, const char[] sArgs)
{
  if (g_WaitingForSayInput[client]) {
    //Peform string search
    int index = SearchKnivesByString(sArgs);
    if (index != -1) {
      ProcessKnifeSelection(client, index);
    }
    else {
      CPrintToChat(client, "%s%t", CHAT_TAG_PREFIX, "Search Found No Results", sArgs);
    }

    //Reset
    g_WaitingForSayInput[client] = false;

    //Bring menu back up
    g_KnivesMenu.DisplayAt(client, 0, MENU_TIME_FOREVER);

    return Plugin_Handled;
  }
  
  return Plugin_Continue;
}

public void OnClientPutInServer(int client)
{
  //Initilise variables
  g_WaitingForSayInput[client] = false;
  g_ClientTargetTeam[client] = TargetTeam_CurrentTeam;
  g_ClientKnives[client][CS_TEAM_T] = DEFAULT_KNIFE_INDEX_T;
  g_ClientKnives[client][CS_TEAM_CT] = DEFAULT_KNIFE_INDEX_CT;
}

public void OnClientConnected(int client)
{
  g_IsPostAdminCheck[client] = false;
}

public void OnClientCookiesCached(int client)
{
  if (g_IsPostAdminCheck[client])
    OnClientPostAdminCheckAndCookiesCached(client);
}

public void OnClientPostAdminCheck(int client)
{
  g_IsPostAdminCheck[client] = true;

  if (AreClientCookiesCached(client))
    OnClientPostAdminCheckAndCookiesCached(client);
}

//Run when PostAdminCheck reached and cookies are cached
//Always run for every client and always after both OnClientCookiesCached and OnClientPostAdminCheck
void OnClientPostAdminCheckAndCookiesCached(int client)
{
  //Don't process if knives have not been loaded yet
  if (!g_AreKnivesLoaded)
    return;

  if (!IsClientInGame(client) || IsFakeClient(client))
    return;

  //For non-VIP's do not load in the stored cookie preferences
  //If the client gets VIP status at a later time, their preferences will still be there
  if (!IsClientVip(client))
    return;

  //Load in cookie values
  char buffer[16];

  GetClientCookie(client, g_TargetTeamCookie, buffer, sizeof(buffer));
  if (strlen(buffer) != 0)
    g_ClientTargetTeam[client] = view_as<TargetTeam>(StringToInt(buffer));

  //Check if the item def can be mapped to an index
  //If not, then we'll reset to the defaults
  GetClientCookie(client, g_KnifeTCookie, buffer, sizeof(buffer));
  int index = g_KnivesDefIndexes.FindValue(StringToInt(buffer));
  if (index != -1) {
    g_ClientKnives[client][CS_TEAM_T] = index;
  }
  else {
    g_ClientKnives[client][CS_TEAM_T] = DEFAULT_KNIFE_INDEX_T;
  }
  
  GetClientCookie(client, g_KnifeCTCookie, buffer, sizeof(buffer));
  index = g_KnivesDefIndexes.FindValue(StringToInt(buffer));
  if (index != -1) {
    g_ClientKnives[client][CS_TEAM_CT] = index;
  }
  else {
    g_ClientKnives[client][CS_TEAM_CT] = DEFAULT_KNIFE_INDEX_CT;
  }
}

public void CSGOItems_OnItemsSynced()
{
  //If already loaded, no need to reload
  if (g_AreKnivesLoaded)
    return;

  //Reset values
  delete g_MainMenu;
  delete g_TargetTeamMenu;
  delete g_KnivesMenu;
  delete g_KnivesDefIndexes;

  //Reset variables
  g_KnivesDefIndexes = new ArrayList(1);
  
  //Temp variables  
  char numStrBuffer[16];
  char mainMenuItemName[64];
  char targetTeamString[64];

  //Create Main Menu
  g_MainMenu = new Menu(MainMenuHandler, MenuAction_Select|MenuAction_Cancel|MenuAction_End|MenuAction_DisplayItem|MenuAction_DrawItem);
  g_MainMenu.Pagination = MENU_NO_PAGINATION;
  g_MainMenu.ExitButton = true;

  Format(mainMenuItemName, sizeof(mainMenuItemName), "%t", "Select Team Target");
  IntToString(MAINMENU_SELECTTEAMTARGET, numStrBuffer, sizeof(numStrBuffer));
  g_MainMenu.AddItem(numStrBuffer, mainMenuItemName);

  Format(mainMenuItemName, sizeof(mainMenuItemName), "%t", "Select Knife");
  IntToString(MAINMENU_SELECTKNIFE, numStrBuffer, sizeof(numStrBuffer));
  g_MainMenu.AddItem(numStrBuffer, mainMenuItemName);

  //Create g_TargetTeamMenu menu
  g_TargetTeamMenu = new Menu(TargetMenuHandler, MenuAction_Select|MenuAction_Cancel|MenuAction_End|MenuAction_DisplayItem|MenuAction_DrawItem);
  g_TargetTeamMenu.ExitBackButton = true;
  g_TargetTeamMenu.SetTitle("%t\n \n", "Select Team Target");

  for (int i = 0; i < view_as<int>(TargetTeam); ++i) {
    GetTargetTeamString(view_as<TargetTeam>(i), targetTeamString, sizeof(targetTeamString));
    CRemoveTags(targetTeamString, sizeof(targetTeamString)); //Remove any tags
    IntToString(i, numStrBuffer, sizeof(numStrBuffer));
    g_TargetTeamMenu.AddItem(numStrBuffer, targetTeamString);
  }
  
  //Create Knives Menu
  g_KnivesMenu = new Menu(KnivesMenuHandler, MenuAction_Select|MenuAction_Cancel|MenuAction_End|MenuAction_DisplayItem|MenuAction_DrawItem);
  g_KnivesMenu.ExitBackButton = true;

  //Add default/random options
  char defaultKnifeNames[64];

  Format(defaultKnifeNames, sizeof(defaultKnifeNames), "%t", "Search Knife");
  IntToString(SEARCH_KNIFE, numStrBuffer, sizeof(numStrBuffer));
  g_KnivesMenu.AddItem(numStrBuffer, defaultKnifeNames);

  Format(defaultKnifeNames, sizeof(defaultKnifeNames), "%t", "Random Knife");
  IntToString(RANDOM_KNIFE, numStrBuffer, sizeof(numStrBuffer));
  g_KnivesMenu.AddItem(numStrBuffer, defaultKnifeNames);

  Format(defaultKnifeNames, sizeof(defaultKnifeNames), "%t", "Default Knife");
  IntToString(DEFAULT_KNIFE, numStrBuffer, sizeof(numStrBuffer));
  g_KnivesMenu.AddItem(numStrBuffer, defaultKnifeNames);

  //Hardcode defaults into menu
  g_KnivesDefIndexes.Push(DEFAULT_KNIFE_DEFINDEX_T);
  g_KnivesDefIndexes.Push(DEFAULT_KNIFE_DEFINDEX_CT);

  //Read all knives from CSGO Items
  for (int i = 0; i < CSGOItems_GetWeaponCount(); ++i) {
    int itemDefinitionIndex = CSGOItems_GetWeaponDefIndexByWeaponNum(i);
    if (CSGOItems_IsDefIndexKnife(itemDefinitionIndex)) {
      //Ignore non-skinnable knives
      if (!CSGOItems_IsSkinnableDefIndex(itemDefinitionIndex))
        continue;

      //Save information
      g_KnivesDefIndexes.Push(itemDefinitionIndex);

      char displayName[64];
      GetKnifeDisplaynameByDefIndex(itemDefinitionIndex, displayName, sizeof(displayName));

      //Add item to menu
      char item[16];
      Format(item, sizeof(item), "%i", g_KnivesDefIndexes.Length-1);
      g_KnivesMenu.AddItem(item, displayName);
    }
  }

  //Knives are now loaded
  g_AreKnivesLoaded = true;

  //Load preferences at this point
  for (int i = 1; i <= MaxClients; ++i) {
    if (IsClientInGame(i) && !IsFakeClient(i) && g_IsPostAdminCheck[i] && AreClientCookiesCached(i))
      OnClientPostAdminCheckAndCookiesCached(i);
  }
}

/*********************************
 *  Hooks
 *********************************/

//Hook to equip knife
public void GiveNamedItem(int client, const char[] classname, const CEconItemView item, int entity)
{
  //Wait until knives are loaded first
  if (!g_AreKnivesLoaded)
    return;

  if (IsFakeClient(client))
    return;
  
  int itemDefinitionIndex = CSGOItems_GetWeaponDefIndexByWeapon(entity);
  if (itemDefinitionIndex == -1)
    return;
  
  if (!CSGOItems_IsDefIndexKnife(itemDefinitionIndex))
    return;

  //Ensure player does not already has a knife
  //This prevents forcefully equipping multiple knives if other plugins give the player a knife without removing the current one
  //Check using m_hMyWeapons instead of slots to ensure other knife slot items (i.e. taser) are allowed
  for (int i = 0; i < GetEntPropArraySize(client, Prop_Send, "m_hMyWeapons"); ++i) {
    int weapon = GetEntPropEnt(client, Prop_Send, "m_hMyWeapons", i);

    if(weapon && IsValidEntity(weapon)) {
      int weaponItemDefinitionIndex = CSGOItems_GetWeaponDefIndexByWeapon(weapon);
      if (CSGOItems_IsDefIndexKnife(weaponItemDefinitionIndex))
        return;
    }
  }
  
  //Eqiup the knife
  EquipPlayerWeapon(client, entity);
}

//Main hook where we override classname of the knife
public Action GiveNamedItemPre(int client, char classname[64], CEconItemView &item, bool &ignoredCEconItemView)
{
  //Wait until knives are loaded first
  if (!g_AreKnivesLoaded)
    return Plugin_Continue;
  
  if (IsFakeClient(client))
    return Plugin_Continue;

  int clientTeam = GetClientTeam(client);

  if (clientTeam != CS_TEAM_T && clientTeam != CS_TEAM_CT)
    return Plugin_Continue;

  int itemDefinitionIndex = CSGOItems_GetWeaponDefIndexByClassName(classname);
  if (itemDefinitionIndex == -1)
    return Plugin_Continue;

  bool isKnife = CSGOItems_IsDefIndexKnife(itemDefinitionIndex);

  if (isKnife && g_ClientKnives[client][clientTeam] != DEFAULT_KNIFE_INDEX_T && g_ClientKnives[client][clientTeam] != DEFAULT_KNIFE_INDEX_CT) {
    int clientKnivesItemDefinitionIndex = g_KnivesDefIndexes.Get(g_ClientKnives[client][clientTeam]);
    if (!CSGOItems_IsDefIndexKnife(clientKnivesItemDefinitionIndex))
      return Plugin_Continue;

    //Change item classname and set ignoredCEconItemView
    CSGOItems_GetWeaponClassNameByDefIndex(clientKnivesItemDefinitionIndex, classname, sizeof(classname));
    ignoredCEconItemView = true;

    return Plugin_Changed;
  }

  return Plugin_Continue;
}

/*********************************
 *  Commands
 *********************************/

//Show Gloves Menu or perform a search
public Action Command_Knife(int client, int args)
{
  //Check if knives are loaded
  if (!g_AreKnivesLoaded) {
    CPrintToChat(client, "%s%t", CHAT_TAG_PREFIX, "Plugin Not Ready");
    return Plugin_Handled;
  }

  //Get VIP status
  if (!IsClientVip(client)) {
    CPrintToChat(client, "%s%t", CHAT_TAG_PREFIX, "Must be VIP");
    return Plugin_Handled;
  }
  
  //Show menu if no args
  if (args == 0)
     g_MainMenu.Display(client, MENU_TIME_FOREVER);
  //Otherwise perform search
  else {
    char searchQuery[255];
    GetCmdArgString(searchQuery, sizeof(searchQuery));
    int index = SearchKnivesByString(searchQuery);

    if (index != -1) {
      ProcessKnifeSelection(client, index);
    }
    else {
      CPrintToChat(client, "%s%t", CHAT_TAG_PREFIX, "Search Found No Results", searchQuery);
    }
  }

  return Plugin_Handled;
}

/*********************************
 *  Menus And Handlers
 *********************************/

//Main menu handler
public int MainMenuHandler(Menu menu, MenuAction action, int client, int param2)
{
  //Get menu info
  char info[64];
  char display[64];
  GetMenuItem(menu, param2, info, sizeof(info), _, display, sizeof(display));
  int selectedIndex = StringToInt(info);


  //For these menu actions, we will check target teams and set the first target team
  int targetTeams[MAX_TARGET_TEAMS];
  int numTargetTeams  = 0;

  if (action == MenuAction_DrawItem || action == MenuAction_DisplayItem || action == MenuAction_Select) {
    //Get target teams
    numTargetTeams = GetClientTargetTeam(client, targetTeams);
  }

  //Handle menu actions
  if (action == MenuAction_DrawItem) {
    //Hacky way to set title
    if (param2 % MAX_MENU_OPTIONS == 0) { 
      char targetTeamString[64];
      GetTargetTeamString(g_ClientTargetTeam[client], targetTeamString, sizeof(targetTeamString));
      CRemoveTags(targetTeamString, sizeof(targetTeamString)); //Remove any tags
      menu.SetTitle("%t (V%s)\n \n%t %s", "Main Menu Title", PLUGIN_VERSION, "Main Menu Targetting Team Title", targetTeamString);
    }

    //Dont show select knife option if no target teams
    if (selectedIndex == MAINMENU_SELECTKNIFE) {
      if (numTargetTeams == 0)
        return ITEMDRAW_DISABLED;
    }
  }
  else if (action == MenuAction_Select) {
    if (selectedIndex == MAINMENU_SELECTTEAMTARGET) {
      g_TargetTeamMenu.DisplayAt(client, 0, MENU_TIME_FOREVER);
    }
    else if (selectedIndex == MAINMENU_SELECTKNIFE) {
      //Don't allow this option if no target teams
      if (numTargetTeams == 0)
        return 0;
      
      g_KnivesMenu.DisplayAt(client, 0, MENU_TIME_FOREVER);
    }
  }
  
  return 0;
}

//Target menu handler
public int TargetMenuHandler(Menu menu, MenuAction action, int client, int param2)
{
  //Get menu info
  char info[64];
  char display[64];
  GetMenuItem(menu, param2, info, sizeof(info), _, display, sizeof(display));
  int selectedIndex = StringToInt(info);
  
  if (action == MenuAction_DrawItem) {
    if (g_ClientTargetTeam[client] == view_as<TargetTeam>(selectedIndex))
      return ITEMDRAW_DISABLED;
  }
  else if (action == MenuAction_DisplayItem) {
    if (g_ClientTargetTeam[client] == view_as<TargetTeam>(selectedIndex)) {
      //Change selected text
      char equipedText[sizeof(display) + 5]; //4 bytes + 1 null terminator
      Format(equipedText, sizeof(equipedText), "%s [*]", display);
      return RedrawMenuItem(equipedText);
    }
  }
  else if (action == MenuAction_Select) {
    //Set target team
    g_ClientTargetTeam[client] = view_as<TargetTeam>(selectedIndex);

    //Save cookie
    if (AreClientCookiesCached(client)) {
      char buffer[16];
      IntToString(selectedIndex, buffer, sizeof(buffer));
      SetClientCookie(client, g_TargetTeamCookie, buffer);
    }

    char targetTeamString[64];
    GetTargetTeamString(view_as<TargetTeam>(selectedIndex), targetTeamString, sizeof(targetTeamString));
    CPrintToChat(client, "%s%t", CHAT_TAG_PREFIX, "Selected Target Team", targetTeamString);

    menu.DisplayAt(client, GetMenuSelectionPosition(), MENU_TIME_FOREVER);
  }
  else if (action == MenuAction_Cancel)
  {
    if (param2 == MenuCancel_ExitBack) {
      //Goto main menu
      g_MainMenu.DisplayAt(client, 0, MENU_TIME_FOREVER);
    }
  }
  
  return 0;
}

//Knives menu handler
public int KnivesMenuHandler(Menu menu, MenuAction action, int client, int param2)
{
  //Get menu info
  char info[64];
  char display[64];
  GetMenuItem(menu, param2, info, sizeof(info), _, display, sizeof(display));
  int selectedIndex = StringToInt(info);

  //For these menu actions, we will check target teams and set the first target team
  int firstTargetTeam = 0;
  int firstFinalIndex  = 0;

  if (action == MenuAction_DrawItem || action == MenuAction_DisplayItem || action == MenuAction_Select) {
    //Get target teams
    int targetTeams[MAX_TARGET_TEAMS];
    int numTargetTeams = GetClientTargetTeam(client, targetTeams);
    if (numTargetTeams == 0)
      return 0;
    
    //Use first target team to display various information (even if more than 1 target team exists)
    firstTargetTeam = targetTeams[0];
    firstFinalIndex = GetFinalKnivesIndex(client, firstTargetTeam, selectedIndex);
  }
  
  //Handle menu actions
  if (action == MenuAction_DrawItem) {
    //Hacky way to set title
    if (param2 % MAX_MENU_OPTIONS == 0) {
      char knifeDisplayName[64];
      GetKnifeDisplaynameByDefIndex(g_KnivesDefIndexes.Get(g_ClientKnives[client][firstTargetTeam]), knifeDisplayName, sizeof(knifeDisplayName));
      menu.SetTitle("%t\n \n%t %s", "Select Knife", "Current Knife", knifeDisplayName);
    }
    
    if (g_ClientKnives[client][firstTargetTeam] ==  firstFinalIndex)
      return ITEMDRAW_DISABLED;
  }
  else if (action == MenuAction_DisplayItem) {
    if (g_ClientKnives[client][firstTargetTeam] ==  firstFinalIndex) {
      //Change selected text
      char equipedText[sizeof(display) + 5]; //4 bytes + 1 null terminator
      Format(equipedText, sizeof(equipedText), "%s [*]", display);
      return RedrawMenuItem(equipedText);
    }
  }
  else if (action == MenuAction_Select) {
    if (selectedIndex == SEARCH_KNIFE) {
      //Wait to get input from chat
      g_WaitingForSayInput[client] = true;
      CPrintToChat(client, "%s%t", CHAT_TAG_PREFIX, "Generic Enter Chat", "Knife Name");
    }
    else {
      //We are selecting a knife, process selection
      ProcessKnifeSelection(client, selectedIndex);
      
      menu.DisplayAt(client, GetMenuSelectionPosition(), MENU_TIME_FOREVER);
    }
  }
  else if (action == MenuAction_Cancel)
  {
    if (param2 == MenuCancel_ExitBack) {
      //Goto main menu
      g_MainMenu.DisplayAt(client, 0, MENU_TIME_FOREVER);
    }
  }
  
  return 0;
}

/*********************************
 *  Helper Functions / Other
 *********************************/

//Get target team string from translations
void GetTargetTeamString(TargetTeam targetTeam, char[] targetTeamString, int maxlen)
{
  switch (targetTeam)
  {
    case TargetTeam_CurrentTeam:
    {
      Format(targetTeamString, maxlen, "%t", "Target Team Current Team");
    }
    case TargetTeam_T:
    {
      Format(targetTeamString, maxlen, "%t", "Target Team T");
    }
    case TargetTeam_CT:
    {
      Format(targetTeamString, maxlen, "%t", "Target Team CT");
    }
    case TargetTeam_Both:
    {
      Format(targetTeamString, maxlen, "%t", "Target Team Both Teams");
    }
  }
}

//Set the clients knife preference
int SetClientKnife(int client, int team, int i)
{
  i = GetFinalKnivesIndex(client, team, i);

  if (i != INVALID_KNIFE_INDEX) {
    //Set knife
    g_ClientKnives[client][team] = i;

    //Save cookie
    if (AreClientCookiesCached(client)) {
      char buffer[16];
      IntToString(g_KnivesDefIndexes.Get(i), buffer, sizeof(buffer));
      SetClientCookie(client, ((team == CS_TEAM_T) ? g_KnifeTCookie : g_KnifeCTCookie), buffer);
    }
  }
  
  return i;
}

//Give the client their knife
void GiveClientKnife(int client)
{
  if(!IsClientInGame(client) || IsFakeClient(client))
    return;

  if (!IsPlayerAlive(client))
    return;

  //Check team
  int clientTeam = GetClientTeam(client);
  if (clientTeam != CS_TEAM_T && clientTeam != CS_TEAM_CT)
    return;
  
  //Check index is valid
  if (g_ClientKnives[client][clientTeam] < 0 || g_ClientKnives[client][clientTeam] > g_KnivesDefIndexes.Length - 1)
    return;

  //Give the weapon (this also removes and kills old knife if it exists)
  //Also switch to the knife slot afterwards
  CSGOItems_GiveWeapon(client, (GetClientTeam(client) == CS_TEAM_T) ? "weapon_knife_t" : "weapon_knife", _, _, CS_SLOT_KNIFE);
}

//Get display names for each knife
//This uses CSGOItems_GetWeaponDisplayNameByDefIndex but with slight modifications
bool GetKnifeDisplaynameByDefIndex(int itemDefinitionIndex, char[] knifeDisplayName, int maxlen)
{
  if (!CSGOItems_IsDefIndexKnife(itemDefinitionIndex))
    return false;
  
  if (!CSGOItems_GetWeaponDisplayNameByDefIndex(itemDefinitionIndex, knifeDisplayName, maxlen))
    return false;

  if (itemDefinitionIndex == DEFAULT_KNIFE_DEFINDEX_T)
    Format(knifeDisplayName, maxlen, "%t", "Default Knife T Display Name");
  else if (itemDefinitionIndex == DEFAULT_KNIFE_DEFINDEX_CT)
    Format(knifeDisplayName, maxlen, "%t", "Default Knife CT Display Name");

  //Add star prefix to display names
  Format(knifeDisplayName, maxlen, "%s%s", "★ ", knifeDisplayName);

  return true;
}

//Get final knife index resolving random knife/default knife options
int GetFinalKnivesIndex(int client, int team, int i)
{
  if(!IsClientInGame(client) || IsFakeClient(client))
    return INVALID_KNIFE_INDEX;

  //Check team
  if (team != CS_TEAM_T && team != CS_TEAM_CT)
    return INVALID_KNIFE_INDEX;
  
  //Handle randomised index
  //Keep picking random number until an index that is different from our current selection is found
  if(i == RANDOM_KNIFE) {
    do {
      i = GetRandomInt(MIN_CONFIG_INDEX, g_KnivesDefIndexes.Length - 1);
    } while (i == g_ClientKnives[client][team]);
  }
  
  //Handle default index
  if (i == DEFAULT_KNIFE) {
    if (team == CS_TEAM_T)
      i = DEFAULT_KNIFE_INDEX_T;
    else if (team == CS_TEAM_CT)
      i = DEFAULT_KNIFE_INDEX_CT;
    else
      return INVALID_KNIFE_INDEX;
  }

  //Finally, ensure index is valid
  if (i < 0 || i > g_KnivesDefIndexes.Length - 1)
    return INVALID_KNIFE_INDEX;

  return i;
}

//Get all teams a client is targetting
int GetClientTargetTeam(int client, int results[MAX_TARGET_TEAMS])
{  
  int numAdded = 0;

  switch (g_ClientTargetTeam[client])
  {
    case TargetTeam_CurrentTeam:
    {
      int clientTeam = GetClientTeam(client);
      if (clientTeam == CS_TEAM_T || clientTeam == CS_TEAM_CT)
        results[numAdded++] = clientTeam;
    }
    case TargetTeam_T:
    {
      results[numAdded++] = CS_TEAM_T;
    }
    case TargetTeam_CT:
    {
      results[numAdded++] = CS_TEAM_CT;
    }
    case TargetTeam_Both:
    {
      results[numAdded++] = CS_TEAM_T;
      results[numAdded++] = CS_TEAM_CT;
    }
  }

  return numAdded;
}

//Process the clients knife selection
bool ProcessKnifeSelection(int client, int selectedIndex)
{
  if (!IsClientInGame(client))
    return false;
  
  //Get target teams
  int targetTeams[MAX_TARGET_TEAMS];
  int numTargetTeams = GetClientTargetTeam(client, targetTeams);
  if (numTargetTeams == 0)
    return false;

  int currentTeam = GetClientTeam(client);

  //Set the clients knife for all of their target teams
  for (int i = 0; i < numTargetTeams; ++i) {
    //Set the client knives using their targetTeam and the final index based on their target team
    int finalIndex = GetFinalKnivesIndex(client, targetTeams[i], selectedIndex);
    SetClientKnife(client, targetTeams[i], finalIndex);

    //Check if we should give the client the knife instantly
    if (g_Cvar_Instant.BoolValue && (currentTeam == targetTeams[i]) && IsPlayerAlive(client))
      GiveClientKnife(client);

    //Get knife display name
    char knifeDisplayName[64];
    GetKnifeDisplaynameByDefIndex(g_KnivesDefIndexes.Get(finalIndex), knifeDisplayName, sizeof(knifeDisplayName));

    //Print selection message
    if (g_Cvar_Instant.BoolValue && IsPlayerAlive(client))
      CPrintToChat(client, "%s%t", CHAT_TAG_PREFIX, "Equipped Knife Instant", knifeDisplayName, ((targetTeams[i] == CS_TEAM_T) ? "Target Team T" : "Target Team CT") );
    else
      CPrintToChat(client, "%s%t", CHAT_TAG_PREFIX, "Equipped Knife Spawn", knifeDisplayName, ((targetTeams[i] == CS_TEAM_T) ? "Target Team T" : "Target Team CT"));
  }

  return true;
}

//Search for knives by string
//Will return index of a knife (including action indexes) or INVALID_KNIFE_INDEX on failure
int SearchKnivesByString(const char[] query)
{
  char buffer[64];
  int startingMatch = INVALID_KNIFE_INDEX, partialMatch = INVALID_KNIFE_INDEX;
  
  //Hard code default and random search phrases
  if (StrEqual("default", query, false))
    return DEFAULT_KNIFE;

  if (StrEqual("random", query, false))
    return RANDOM_KNIFE;

  //Search for everything else
  for (int i = MIN_CONFIG_INDEX; i < g_KnivesDefIndexes.Length; ++i) {
    //Get knife name from CSGOItems
    CSGOItems_GetWeaponDisplayNameByDefIndex(g_KnivesDefIndexes.Get(i), buffer, sizeof(buffer));
    
    //First find exact matches
    if (StrEqual(buffer, query, false))
      return i;
    
    int pos = StrContains(buffer, query, false);

    //Then try to find starts with match
    if (pos == 0)
      startingMatch = i;

    //Then try to find any partial matches (anywhere in string)
    if (pos > 0)
      partialMatch = i;
  }

  //Prefer startingMatches over partialMatches
  return (startingMatch != INVALID_KNIFE_INDEX) ? startingMatch : partialMatch;
}


/*********************************
 *  Stocks
 *********************************/

stock bool IsClientVip(int client)
{
  if (!IsClientConnected(client) || IsFakeClient(client))
    return false;
  
  char buffer[2];
  g_Cvar_VipFlag.GetString(buffer, sizeof(buffer));

  //Empty flag means open access
  if(strlen(buffer) == 0)
    return true;

  return ClientHasCharFlag(client, buffer[0]);
}

stock bool ClientHasCharFlag(int client, char charFlag)
{
  AdminFlag flag;
  return (FindFlagByChar(charFlag, flag) && ClientHasAdminFlag(client, flag));
}

stock bool ClientHasAdminFlag(int client, AdminFlag flag)
{
  if (!IsClientConnected(client))
    return false;
  
  AdminId admin = GetUserAdmin(client);
  if (admin != INVALID_ADMIN_ID && GetAdminFlag(admin, flag, Access_Effective))
    return true;
  return false;
}