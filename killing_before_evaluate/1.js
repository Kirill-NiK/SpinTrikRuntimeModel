var main1 = function()
{
	print(2);
}

var main = function()
{
	Threading.startThread("main1", "main1");
	Threading.killThread("main1");
	print(1);
}
