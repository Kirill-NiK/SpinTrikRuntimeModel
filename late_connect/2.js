var main1 = function()
{
	script.run();
	print(1);
	script.quit();
}

var main = function()
{
	script.run();
	Threading.startThread("main1", "main1");
	script.quit();
	print(2);
}
