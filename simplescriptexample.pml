byte count = 255; // - верификатор не ругается на переполнение
bit a = 1;
bit x = 0;
mtype {aaaa, bbbb, cccc};
mtype {aa, bb, cc};

chan sensorsThreadEvents = [10] of {mtype};

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
	a1();
}

inline a1()
{
	skip;
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
proctype C()
{
	x = 0;
	do
	:: false -> x = 1;
	:: false -> x = 0;
	:: else -> break;
 	od;
	printf("exit from cycle");
	
	b2: printf("end of proctype");
}
int i;
inline foo()
{
	true;
	here: printf("inside"); i++;
	if 
	:: i <= 10 -> goto here;
	:: else -> skip;
	fi;	
	
}

inline doSmth()
{
	byte x = 1; x==1 -> printf("a"); goto aaa;
	aaa: skip;
}

proctype sensorsThread() /* на самом деде существует много отдельных потоков для различных сенсоров */
{
	mtype signal;
	end: progress: do
	:: sensorsThreadEvents ? signal ->
		if
		:: signal == aaaa -> skip;
	    fi;
	od;
}

init{
	// run A();
	//byte y = -1;
	//random(0, 100, y);
	//printf("%d\n", y);
	//bit x = 1;
	//if
	//:: !x -> printf("x == 0");
	//:: else -> printf("x == 1");
	//fi;
	//atomic {x -> printf("hype!")}
	//printf("NOOOOO");

	//here: true;
//	true;
//	int j = -2;
//	here: true;
//	 printf("outside");
//	foo();
//	j++;
//	if 
//	:: j == -1 -> goto here;
//	:: j != -1 -> skip;
//	fi;
//	printf("конец");
//goto end;
//printf("1");
//aaa: true;
//printf("2");
//do
//:: 1 -> doSmth();
//:: else -> break;
//od;
//printf("3");
//doSmth();
//printf("4");
//bit mThreads[256] = 1;
//short tmp = 1;
//if
//:: (tmp == -1) || (!mThreads[tmp])  ->
//	printf("!= -1")
//:: else -> printf("== -1");
//fi;
//mtype f = aa;
//f++;
//mtype d = bbbb;
//printf("%d", f);
//printf("%d", bb);
//short x;
//random(-1, 5, x);
//!0 -> printf("%d", x);
do
::
	if
	:: break;
	:: break;
	fi;
od;
printf("Hellow, world!");
run sensorsThread();
}
