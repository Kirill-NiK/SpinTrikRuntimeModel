var main1 = function()
{
	print(1);
}

var main = function()
{
	Threading.startThread("main1", "main1");
	print(2);
	Threading.startThread("main1", "main1");
}