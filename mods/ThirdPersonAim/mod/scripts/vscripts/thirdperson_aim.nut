untyped

global function TPA_Init
global function TPA_Toggle
global function TPA_Shutdown

struct
{
	bool enabled = false
	entity owner
	entity cockpit
	table saved = {}
	var reticle = null
	float collisionFraction = -1.0
	bool adsFirstPerson = false
	bool returningToShoulder = false
} file

void function TPA_Init()
{
	RegisterButtonPressedCallback( KEY_6, TPA_Toggle )
	thread TPA_Update()
}

void function TPA_Toggle( int button )
{
	file.enabled = !file.enabled
	if ( !file.enabled )
		TPA_ReleaseCamera()
}

void function TPA_Shutdown()
{
	file.enabled = false
	TPA_ReleaseCamera()
}

void function TPA_ReleaseCamera()
{
	if ( IsValid( file.cockpit ) )
		file.cockpit.Show()
	file.cockpit = null
	file.collisionFraction = -1.0
	file.adsFirstPerson = false
	file.returningToShoulder = false
	if ( file.reticle != null )
	{
		RuiDestroy( file.reticle )
		file.reticle = null
	}
	if ( file.saved.len() == 0 )
		return
	if ( IsValid( file.owner ) )
		file.owner.ClientCommand( "firstperson" )
	foreach ( name, value in file.saved )
		SetConVarFloat( name, value )
	// An interrupted shoulder session can leave its hidden viewmodels as the captured value.
	SetConVarBool( "r_drawviewmodel", true )
	SetConVarBool( "c_thirdpersonshoulder", false )
	file.saved.clear()
	file.owner = null
}

void function TPA_Update()
{
	float lastUpdate = Time()
	while ( true )
	{
		WaitFrame()
		float elapsed = Time() - lastUpdate
		lastUpdate = Time()
		entity player = GetLocalClientPlayer()
		bool usable = file.enabled && IsValid( player ) && IsAlive( player )
		if ( usable )
			usable = GetLocalViewPlayer() == player && player.GetParent() == null
				&& !player.IsScriptMenuOn() && !player.ContextAction_IsActive()
				&& !IsWatchingKillReplay() && !IsWatchingSpecReplay()
		if ( !usable )
		{
			TPA_ReleaseCamera()
			continue
		}
		bool titan = player.IsTitan()
		entity weapon = player.GetActiveWeapon()
		string weaponClassName = IsValid( weapon ) ? weapon.GetWeaponClassName() : ""
		bool antiTitanWeapon = weaponClassName == "mp_weapon_defender" || weaponClassName == "mp_weapon_arc_launcher" || weaponClassName == "mp_weapon_rocket_launcher"
		bool sniperWeapon = weaponClassName == "mp_weapon_sniper" || weaponClassName == "mp_weapon_dmr" || weaponClassName == "mp_weapon_doubletake"
		bool adsFirstPersonWeapon = !titan && (weaponClassName == "mp_weapon_arc_launcher" || weaponClassName == "mp_weapon_rocket_launcher" || sniperWeapon)
		bool adsFirstPersonAiming = adsFirstPersonWeapon && player.GetZoomFrac() > 0.0
		bool shoulderActive = GetConVarBool( "c_thirdpersonshoulder" )

		if ( file.adsFirstPerson )
		{
			if ( file.returningToShoulder )
			{
				if ( shoulderActive )
				{
					file.adsFirstPerson = false
					file.returningToShoulder = false
				}
			}
			else if ( adsFirstPersonAiming )
			{
				SetConVarBool( "cl_always_draw_3p_player", false )
				SetConVarBool( "r_drawviewmodel", true )
				TPA_UpdateReticle( true )
				continue
			}
			else
			{
				file.returningToShoulder = true
				player.ClientCommand( "thirdpersonshoulder" )
				continue
			}
		}

		// The game can leave shoulder view during Titan transitions or a manual firstperson command.
		if ( file.saved.len() != 0 && !shoulderActive && !file.adsFirstPerson )
		{
			file.enabled = false
			TPA_ReleaseCamera()
			continue
		}

		if ( file.saved.len() == 0 )
		{
			foreach ( name in [ "cam_idealdist", "cam_idealyaw", "cam_idealpitch", "cam_ideallag", "cam_idealdelta",
				"c_mindistance", "c_maxdistance", "c_minpitch", "c_maxpitch", "cam_collision", "c_thirdpersonshoulder", "c_thirdpersonshoulderoffset",
				"c_thirdpersonshoulderheight", "c_thirdpersonshoulderdist", "c_thirdpersonshoulderaimdist", "cl_always_draw_3p_player", "r_drawviewmodel" ] )
				file.saved[name] <- GetConVarFloat( name )
			file.owner = player
			SetConVarFloat( "cam_ideallag", 0.0 )
			SetConVarFloat( "cam_idealdelta", 360.0 )
			SetConVarFloat( "c_mindistance", 0.0 )
			SetConVarFloat( "c_maxdistance", 1000.0 )
			SetConVarFloat( "c_minpitch", -89.0 )
			SetConVarFloat( "c_maxpitch", 89.0 )
			SetConVarBool( "cam_collision", false )
			// This command is client-only and does not require sv_cheats.
			SetConVarBool( "c_thirdpersonshoulder", false )
			player.ClientCommand( "thirdpersonshoulder" )
		}

		if ( adsFirstPersonAiming && !file.adsFirstPerson )
		{
			file.adsFirstPerson = true
			file.returningToShoulder = false
			TPA_UpdateReticle( true )
			player.ClientCommand( "firstperson" )
			continue
		}

		TPA_UpdateReticle( titan || antiTitanWeapon || (sniperWeapon && adsFirstPersonAiming) )
		// Keep the complete world model and remove the headless first-person body.
		SetConVarBool( "cl_always_draw_3p_player", !titan )
		SetConVarBool( "r_drawviewmodel", titan )
		entity cockpit = titan ? player.GetCockpit() : null
		if ( file.cockpit != cockpit )
		{
			if ( IsValid( file.cockpit ) )
				file.cockpit.Show()
			file.cockpit = cockpit
		}
		vector eye = player.EyePosition()
		vector eyeAngles = player.EyeAngles()
		float zoom = player.GetZoomFrac()
		float distance = clamp( Graph( zoom, 0.0, 1.0, GetConVarFloat( titan ? "tp_titan_distance" : "tp_distance" ), GetConVarFloat( titan ? "tp_titan_ads_distance" : "tp_ads_distance" ) ), 10.0, titan ? 800.0 : 160.0 )
		float offset = clamp( GetConVarFloat( titan ? "tp_titan_offset" : "tp_offset" ), titan ? -250.0 : -60.0, titan ? 250.0 : 60.0 ) * Graph( zoom, 0.0, 1.0, 1.0, 0.8 )
		float height = clamp( GetConVarFloat( titan ? "tp_titan_height" : "tp_height" ), 0.0, titan ? 150.0 : 30.0 )
		vector attackOrigin = eye
		vector attackDirection = AnglesToForward( eyeAngles )
		if ( IsValid( weapon ) )
		{
			attackOrigin = weapon.GetAttackPosition()
			attackDirection = weapon.GetAttackDirection()
		}
		TraceResults aim = TraceLine( attackOrigin, attackOrigin + attackDirection * GetConVarFloat( "tp_aim_distance" ), player, TRACE_MASK_SHOT, TRACE_COLLISION_GROUP_NONE )
		vector feet = player.GetOrigin()
		float lift = (eye.z - feet.z) * 0.25
		// The native chase camera starts at render origin + 75% of view height.
		vector base = feet + <0, 0, (eye.z - feet.z) * 0.75>
		vector angles = eyeAngles
		vector origin = eye
		origin = base - AnglesToForward( angles ) * distance + AnglesToRight( angles ) * offset + AnglesToUp( angles ) * (height + lift)
		float radius = titan ? 12.0 : 4.0
		TraceResults wall = TraceHull( eye, origin, < -radius, -radius, -radius >, <radius, radius, radius>, player, TRACE_MASK_SOLID, TRACE_COLLISION_GROUP_NONE )
		float targetFraction = wall.startSolid ? 0.0 : max( 0.0, wall.fraction - 0.02 )
		float fraction = targetFraction
		if ( titan )
			file.collisionFraction = -1.0
		else
		{
			// Retract immediately to avoid walls; recover at a fixed rate independent of FPS.
			if ( file.collisionFraction < 0.0 || targetFraction < file.collisionFraction )
				file.collisionFraction = targetFraction
			else
				file.collisionFraction = min( targetFraction, file.collisionFraction + elapsed * 3.0 )
			fraction = file.collisionFraction
		}
		distance *= fraction
		offset *= fraction
		height *= fraction
		SetConVarFloat( "cam_idealdist", titan ? distance * 0.5 : distance )
		SetConVarFloat( "cam_idealyaw", AngleDiff( eyeAngles.y, angles.y ) )
		SetConVarFloat( "cam_idealpitch", AngleDiff( eyeAngles.x, angles.x ) )
		SetConVarFloat( "c_thirdpersonshoulderoffset", offset )
		SetConVarFloat( "c_thirdpersonshoulderheight", height + lift )
		SetConVarFloat( "c_thirdpersonshoulderaimdist", 0.0 )
		if ( file.reticle != null )
		{
			var screen = Hud.ToScreenSpace( aim.endPos )
			float[2] size = GetScreenSize()
			RuiSetFloat2( file.reticle, "msgPos", <float(screen[0]) / size[0] - 0.0028, float(screen[1]) / size[1] - 0.031, 0> )
			RuiSetFloat( file.reticle, "msgAlpha", screen[2] ? 1.0 : 0.0 )
		}
	}
}

void function TPA_UpdateReticle( bool useNative )
{
	if ( useNative )
	{
		if ( file.reticle != null )
		{
			RuiDestroy( file.reticle )
			file.reticle = null
		}
		return
	}
	if ( file.reticle != null )
		return
	file.reticle = RuiCreate( $"ui/cockpit_console_text_top_left.rpak", clGlobal.topoFullScreen, RUI_DRAW_HUD, 100 )
	RuiSetInt( file.reticle, "lineNum", 1 )
	RuiSetFloat2( file.reticle, "msgPos", <0.4972, 0.469, 0> )
	RuiSetString( file.reticle, "msgText", "+" )
	RuiSetFloat( file.reticle, "msgFontSize", 22.0 )
	RuiSetFloat( file.reticle, "msgAlpha", 1.0 )
	RuiSetFloat3( file.reticle, "msgColor", <1, 1, 1> )
}
