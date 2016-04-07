byte count = 255; // - верификатор не ругается на переполнение
bit a = 1;
bit x = 0;

inline random(min, max, x)
{
	atomic {
		assert(min <= max);
		x = min;
		do
		:: (x < max) -> 
			if
			:: true -> break;
			:: true -> skip;
			fi;
			x++;
		:: else -> break;
		od
	}
}

proctype A() // - а если таких процессов много - атомик делать? а в реальной системе?
{
	progress: do
	:: count++;
	:: (count > 0) -> count--;
	:: (count == 0) -> skip; 
	:: true-> 
		do
		:: a++;
		:: a--;
		:: break;
		od;
	:: break;
	od;
}

// active proctype B()
//{
//	assert(count >= 0);
//}
active proctype C()
{
	x = 0;
	do
	:: x = 1;
	:: x = 0;
 	od;
}

init{
	// run A();
	//byte y = -1;
	//random(0, 100, y);
	//printf("%d\n", y);
	bit x = 1;
	//if
	//:: !x -> printf("x == 0");
	//:: else -> printf("x == 1");
	//fi;
	atomic {x -> printf("hype!")}
	printf("NOOOOO");
	
}
