#if defined _SelfMute_V2_included
 #endinput
#endif
#define _SelfMute_V2_included

/**
* Check if client has target selfmuted in text chat

* @param client        Client Index
* @param target        Target Index


* @return            True if selfmute was placed, False otherwise
**/
native bool SelfMute_GetTextSelfMute(int client, int target);

/**
* Check if client has target selfmuted in voice chat

* @param client        Client Index
* @param target        Target Index


* @return            True if selfmute was placed, False otherwise
**/
native bool SelfMute_GetVoiceSelfMute(int client, int target);

/**
* Check if client has target selfmuted in voice chat and text chat

* @param client        Client Index
* @param target        Target Index


* @return            True if selfmute was placed, False otherwise
**/
native bool SelfMute_GetSelfMute(int client, int target);
