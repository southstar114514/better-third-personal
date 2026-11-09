untyped

global function TPA_ServerInit

void function TPA_ServerInit()
{
	AddClientCommandCallback( "TPA_ApplySettings", TPA_ApplySettings )
}

bool function TPA_ApplySettings( entity player, array<string> args )
{
	if ( !IsValid( player ) )
		return false

	ClientCommand( player, "c_thirdpersonshoulderoffset " + GetConVarString( "tp_offset" ) )
	ClientCommand( player, "c_thirdpersonshoulderheight " + GetConVarString( "tp_height" ) )
	ClientCommand( player, "c_thirdpersonshoulderdist " + GetConVarString( "tp_distance" ) )
	ClientCommand( player, "c_thirdpersonshoulderaimdist " + GetConVarString( "tp_aim_distance" ) )
	ClientCommand( player, "cam_collision 1" )
	ClientCommand( player, "thirdpersonshoulder" )
	return true
}
