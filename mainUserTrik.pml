/* Имитируем действия пользователя, который рандомно нажимает клавиши на контроллере, */
/* Модель разрабатывается для того, чтобы проверить deadlock, livelock, starvation при таких действиях */

mtype = {up, left, down, power, back, right, ok, reset};

chan events = [0] of {mtype};

mtype button;
 
/* Каждому состоянию эквивалентна пара виджет + возможность действия (???). */
int state = 0;
proctype User() 
{
progress: do	
	:: events ! up; printf("MSC: up pressed\n")
	:: events ! left; printf("MSC: left pressed\n")
	:: events ! down; printf("MSC: down pressed\n")
	:: events ! power; printf("MSC: power pressed\n")
	:: events ! back; printf("MSC: back pressed\n")
	:: events ! right; printf("MSC: right pressed\n")
	:: events ! ok; printf("MSC: ok pressed\n")
	:: events ! reset; printf("MSC: up pressed\n")
	od
}

proctype TrikGuiMain() 
{
	do
	:: (state == 0) -> events ? button;
		if
		:: (button == up) -> printf("MSC: got \"up\" event\n")
		:: (button == left) -> printf("MSC: got \"left\" event\n")
		:: (button == down) -> printf("MSC: got \"down\" event\n")
		:: (button == power) -> state = 1; printf("MSC: got \"power\" event\n")
		:: (button == back) -> printf("MSC: got \"back\" event\n")
		:: (button == right) -> printf("MSC: got \"right\" event\n")
		:: (button == ok) -> printf("MSC: got \"ok\" event\n")
		:: (button == reset) -> state = 1; printf("MSC: got \"reset\" event\n")
		fi
	:: (state == 1) -> break
	od	
}

init 
{
	atomic {run User();	run TrikGuiMain()}
}

never
{
	do 
	:: (timeout == true) -> break
	:: else
	od
}