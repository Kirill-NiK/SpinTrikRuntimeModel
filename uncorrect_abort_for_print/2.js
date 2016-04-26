var main1 = function()
{
	print(2);
	script.run();
	print(3);
	Threading.startThread("main", "main");
	print(4);
}

var main = function()
{
	script.run();
	Threading.startThread("main1", "main1");
	print(1);
	while (true) {print(7)};
}