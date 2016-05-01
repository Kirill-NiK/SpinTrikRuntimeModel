var main1 = function()
{
	Threading.joinThread("main");
}

var main = function()
{
	Threading.startThread("main1", "main1");
	Threading.joinThread("main1");
}