untyped

global function TPA_SharedInit

void function TPA_SharedInit()
{
	AddCallback_OnRegisteringCustomNetworkVars( TPA_RegisterFunctions )
}

void function TPA_RegisterFunctions()
{
	Remote_RegisterFunction( "ServerCallback_TPA_Apply" )
}
