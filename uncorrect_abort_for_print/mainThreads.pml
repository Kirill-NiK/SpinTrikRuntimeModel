/* SPIN-ом выдаваемая ошибка (например, при spin -a mainThreads.pml) типа "... missing array index ..." - это известный баг, но он никак не влияет на работу верификатора */
//#define NO_LOGGING // только для QLOG_INFO()
#define S 2 // максимальное количество запущенных скриптов (engineThreads) S < 256
#define N 3 // максимальная длина очереди event-ов для каждого потока N < 256
#define MaxThreadCount 10 // максимальное ожидамое кол-во активных процессов в модели (неообходимо для ускорения верификации)

#ifndef NO_LOGGING
 #define LOG(x) printf(x); printf("\n")
#else
 #define LOG(x) skip
#endif

 /* enum State */
 #define ready 0
 #define starting 1
 #define stopping 2
 #define running 3
 
#define mutex bit
/* кол-во мьютексов в модели */
#define MutexCount 2
/* обозначим их соответственно, чтоб было удобней ориентироваться */
#define _mResetMutex 0
#define _mThreadsMutex 1

/* ниже будут описаны дефайны для LTL-формул */
/* проблема использования labels в некоторых случаях состоит в неизвестном кол-ве engineThreads */
#define p1 GUIThread@showError
#define q1 mErrorMessage
/* определяемые ниже метки для проверки необходимого свойства нужно проверить снова при расширении модели User-ом */
#define p2 scriptWorkerThread@doRunInvoked
#define q2 scriptWorkerThread@completedEmitted
/* r2 можно переделать, но для S==2 пойдет */
#define r2 (isAutonomousCycle[0] || isAutonomousCycle[1])
#define p3 mInEventDrivenMode
#define p4 mState != starting 

byte mState = ready; /* ScriptEngineWorker:state */
bool mInEventDrivenMode = false; /* находится в ScriptExecutionControl, True, if a system is in this mode, so it shall wait for events when script is executed. (c) */
mutex mResetMutex = 1; /* мьютекс для mResetStarted; поскольку все операции с тредами должны быть атомарными */ // можно поставить проверку, что в конце работы программы всегда в 1 будет. аналогично с другими переменными
bool mResetStarted = false; /* флаг, показывающий, что начался reset, во время которого все остальные операции с тредами должны отменяться; */
mutex mThreadsMutex = 1; /* для mFinishedThreads, mPreventFromStart, mThreads */
bit mFinishedThreads[S] = 0; /* список завершившихся тредов - у меня будут инты, в проге - стринги */
bit mPreventFromStart[S] = 0; /* список тредов, которые ещё не были запущены, но должны быть завершены - у меня будут инты, в проге - стринги */
bit mThreads[S] = 0; /* хэш (который мы моделируем как массив), отображающий имя треда на сам тред, используется для получения доступа к отдельным потокам; */

short threadId = 0; /* имя треда, для :main: engine thread - 0, нужен только для модели, равен самому левому нулевому значению в mThreads */

/* ниже используемые сигналы-события для всех потоков, параметры - в глобальные переменные, если необходимо. emptyEvent --- для заглушки */
mtype {emptyEvent, INVOKEdoRun, completed, start, runScript, abortScript, stopRunning, stopWaiting, quitSignal}; 

/* ниже каналы, моделирующие очередь событий в соответствующих потоках */
chan GUIThreadEvents = [N] of {mtype};
chan connectionsThreadEvents = [N] of {mtype};
chan sensorsThreadEvents = [N] of {mtype};
chan scriptWorkerThreadEvents = [N] of {mtype};
chan engineThreadEvents [S] = [N] of {mtype}; // можно смоделировать удаление mEngine->deleteLater();, а в других методах return mEngine->isEvaluating(); нет проверки.

mtype {FailedToOpenFileException, returnControl}; /* бросаемые исключения и возврат из обработчика (returnControl) */
chan catch = [0] of {mtype}; /* рандеву-канал, эмулирующий обработку вызванных исключений */

bit abortEvaluationInvoked[S] = 0; /* массив, который обозначает, что engine->abortEvaluation() была вызвана */

byte mThreadCount = 0; /* число engine-потоков */

bool timerTimeout = false; /* флаги, моделирующие ивенетлуп в ScriptExecutionControl::wait */
bool loopStopWaiting = false; /* флаги, моделирующие ивенетлуп в ScriptExecutionControl::wait */

bool mErrorMessage = false; /* флаг, который будет true, если mErrorMessage в программе непустой */

bool isAutonomousCycle[S] = false; /* массив флагов, сигнализирующий, что какой-то из потоков может находиться в бесконечном цикле ожидания */
//bool autonomousCycleExists = false;

bool RunningWidget = false; /* флаг для модели, показывающий, что RunnungWidget запущен */

typedef mutexes /* некоторый официальный хак, чтоб смоделировать матрицу с информацией по каждому мьютексу */
{
	bool forThread[MaxThreadCount] = 1; /* ни один из потоков не блокировал мьютексы */
};

mutexes mutexInfo[MutexCount]; /* матрица, чтоб проверять корректность блокировки и разблокировки мьютекса в различных потоках */

inline emit(thread, signal) /* в очередь событий \a thread добавить сигнал (событие) \a signal, _ВНИМАНИЕ_: последовательно добавляем в очередь */
{
	true;//???assert(nfull(thread)); /* Если копятся ивенты, значит что-то пошло не так... */
	endQueue: thread ! signal; // точно так можно сделать?
}

inline lock(_s, __s, _thread) /* блокировка мьютекса в определенном потоке */
{
	atomic {
		assert(mutexInfo[__s].forThread[_thread]); /* проверка на deadlock */
		_s == 1 ->
		mutexInfo[__s].forThread[_thread] = 0;
		_s--;
	}; 
}

inline unlock(_s, __s, _thread) /* разблокировка мьютекса в определенном потоке */
{
	/* Qt: Attempting to unlock a mutex in a different thread to the one that locked it results in an error. Unlocking a mutex that is not locked results in undefined behavior. */
	atomic {
		assert(_s == 0); /* из документации Qt --- неопределенное поведение */
		assert(!mutexInfo[__s].forThread[_thread]); /* попытка разблочить мьютекс из потока, где этот мьютекс не был заблочен */
		mutexInfo[__s].forThread[_thread] = 1;
		_s++;
	};
}

inline throw(exception) /* моделирование бросания исключения */
{
	catch ! exception;
}

inline random(min, max, x) /* рандомное число записывается в x: min <= x <= max */
{
	atomic {
		assert(min <= max);
		x = min;
		do
		:: x < max -> 
			if
			:: break;
			:: x++;
			fi;
		:: x == max -> break;
		od;
	};
}

inline tryLockReset() /* Threading::tryLockReset(), но не возвращается значение, ибо inline */
{
	lock(mResetMutex, _mResetMutex, _pid);
	if
	:: mResetStarted -> unlock(mResetMutex, _mResetMutex, _pid);
	:: else -> skip;
	fi;
}

inline abort(thrId) /* ScriptThread::abort() для конкретного нашего потока: thread->abort(); */
{
	abortEvaluationInvoked[thrId] = 1;
	endUselessCalls__: emit(engineThreadEvents[thrId], stopRunning); // вообще, тут зависнуть не должен, мб убрать?
}

inline joinThread(idT) /* Threading::joinThread(const QString &threadId) */
{
	true; /* костыль для использования метки в начале inline, взято из официальной документации */
	joinThread_call: skip;
	short tmp;
	random(-1, S - 1, tmp);
	lock(mThreadsMutex, _mThreadsMutex, _pid);
	do // добавить заранее проверку на существующий поток и написать соответствующий баг репорт
	:: /* длинное условие, которое, возможно, потребуется явно прописать тут, для более адекватной модели - "пока или не закончил или не начал работать" */
		unlock(mThreadsMutex, _mThreadsMutex, _pid);
		if 
		:: mResetStarted -> goto joinThread_return;
		:: else -> skip;
		fi;
		lock(mThreadsMutex, _mThreadsMutex, _pid);
	:: (tmp != -1) -> break; /* крутимся цикле, пока не будет reset-а при t == -1 */
	od;
	//if /* моделируем "затратный" цикл обычным if-ом так можно?? */
	//:: tmp == -1 -> mResetStarted -> goto joinThread_return;
	//:: tmp != -1 ->
	//	unlock(mThreadsMutex, _mThreadsMutex, _pid);
	//	if 
	//	:: mResetStarted -> goto joinThread_return;
	//	:: else -> skip;
	//	fi;
	//	lock(mThreadsMutex, _mThreadsMutex, _pid);
	//:: tmp != -1 -> skip;
	//fi;
	if /* mFinishedThreads.contains(threadId) */
	:: unlock(mThreadsMutex, _mThreadsMutex, _pid); goto joinThread_return;
	:: skip;
	fi;
	unlock(mThreadsMutex, _mThreadsMutex, _pid);
	if 
	// вообще, это неаккуратно, вдруг на mThreads[tmp] запишется другой тред, но правка приведет к сильному усложнению модели, поэтому допускаем такое вычисление.
	:: tmp != idT -> endInfiniteJoin: !mThreads[tmp]; // добавить предложение на максимальное время ожидания?
	:: else -> LOG("QThread::wait: Thread tried to wait on itself"); /* данное сообщение выводится не в логе Q_LOG */
	fi;
	joinThread_return: skip;	
}

inline killThread() /* Threading::killThread(const QString &threadId) */
{
	true; /* костыль для использования метки в начале inline, взято из официальной документации */
	killThread_call: skip;
	tryLockReset();
	if 
	:: mResetStarted -> goto killThread_return;
	:: else -> skip;
	fi;
	lock(mThreadsMutex, _mThreadsMutex, _pid);
	short tmp;
	random(-1, S - 1, tmp);
	if
	:: (tmp == -1) || !mThreads[tmp] ->
		if
		:: (tmp == -1) || mFinishedThreads[tmp] -> LOG("Threading: killing thread that is not started yet ... will be prevented from running");
			if
			:: (tmp != -1) -> mPreventFromStart[tmp] = 1; // тут не совсем верное моделирование, то есть может так быть, что в prevent попадет всё, что угодно
			:: else -> skip;
			fi;
		:: else -> LOG("Threading: killing already finished thread, ignoring");
		fi;
	:: else ->
		LOG("Threading: killing thread ...");
		/* ScriptThread::abort() */
		// так как множественный stopRunning не падает в реальной модели, запретим "лишние" emits?
		endUselessCalls_: abort(tmp); // может, стоит подробно выписывать в таких случаях, чтоб поставить метку end, иначе тут-то не работает
	fi;
	unlock(mThreadsMutex, _mThreadsMutex, _pid);
	unlock(mResetMutex, _mResetMutex, _pid);
	killThread_return: skip;
}

inline clear(_arr, _len) /* обнуляет массив длиной _len */
{
	atomic {
		assert(_len > 0);
		byte i = 0;
		do
		:: i < _len -> _arr[i] = 0; i++;
		:: i == _len -> break;
		od;
	};
}

inline script_run() /* ScriptExecutionControl::run() */
{
	mInEventDrivenMode = true;
}

inline script_wait() /* ScriptExecutionControl::wait(const int &milliseconds) */
{
	/* по сути объявления loopStopWaiting и timerTimeout ниже означают места объявлений коннектов в реальной программе */
	loopStopWaiting = false;
	timerTimeout = true; /* это означает в модели, что мы указали достаточно большое время, за которое может произойти многое */ // timerTimeout = true это временный фикс одного бага
	/* можно смоделировать более детально, но затратно по ресурсам: */
//	if // < 0, 0, >0, <2^32
//	:: run Timer();
//	:: skip; /* означает, что время поставлено очень-очень большое */
//	fi;
	endLoop: timerTimeout || loopStopWaiting; /* loop.exec(); */
}

inline script_reset() /* ScriptExecutionControl::reset() */
{
	mInEventDrivenMode = false;
	loopStopWaiting = true;
	/* удаление конечного числа таймеров */
}

inline script_quit() /* ScriptExecutionControl::quit() */
{
	/* два коннекта - direct с сигналом и auto со слотом */
	byte runningThread = 0; // можно сделать стоп раннинг в случайном порядке. надо?
	do /* --- с сигналом, по всем потокам вызываем stopRunning */
	:: runningThread < S ->
		if 
		:: mThreads[runningThread] ->
			endUselessCalls: emit(engineThreadEvents[runningThread], stopRunning); 
		:: else -> skip;
		fi;
		runningThread++;
	:: else -> break;
	od;
	/* ScriptEngineWorker::onScriptRequestingToQuit() --- со слотом */
	emit(scriptWorkerThreadEvents, quitSignal); /* в реальной системе autoconnection, но он всегда преобразуется в queuedconnection */
}

inline printCommand() /* это тот print(), который регистрируется так: registerUserFunction("print", print); */
{
	true; /* костыль для использования метки в начале inline, взято из официальной документации */
	/* finite cycle removed */
	/* QTextStream(stdout) << result << "\n"; --- полагаем. что ошибок быть не может, это вывод текста в стандартный вывод */
	evaluateScriptSendMessage_call: skip;
	assert(!abortEvaluationInvoked[id]); /* поставили такой ассерт, так как в wiki-документации проекта сказано, что заранее прерванный evaluate будет ошибочным */
	showMessageForAllConnections: skip; /* не очень важно, direct- или queued- connections, но вроде direct- */
	evaluateScriptSendMessage_return: skip;
	/* тут ещё что-то возвращается, но нам это не очень важно */
}

inline threading_reset() /* Threading::reset() */
{
	true; /* костыль для использования метки в начале inline, взято из официальной документации */
	threading_reset_call: skip;
	atomic {
		tryLockReset(); // ВНИМАНИЕ: atomic здесь - временный фикс
		if 
		:: mResetStarted -> goto threading_reset_return;
		:: else -> skip;
		fi;
	};
	mResetStarted = true;
	unlock(mResetMutex, _mResetMutex, _pid);
	LOG("Threading: reset started");
	/* mMessageMutex.lock(); ...; mMessageMutex.unlock(); --- пока не знаю, надо ли моделировать, но не стоит забывать */
	lock(mThreadsMutex, _mThreadsMutex, _pid);
	
	byte k = 0;
	do
	:: k < S -> 
		if
		:: mThreads[k] ->
			script_reset(); /// TODO: find more sophisticated solution to prevent waiting after abortion (c)
			abort(k);			
		:: else -> skip;
		fi;
		k++;
	:: else -> break;
	od;
	
	clear(mFinishedThreads, S);
	unlock(mThreadsMutex, _mThreadsMutex, _pid);
	script_reset();
	
	mThreadCount == 0; /* waitForAll(); */
	/* много удалений, связанных с очередями сообщений */
	LOG("Threading: reset ended");
	mResetStarted = false;
	threading_reset_return: skip;
}

inline brick_reset() /* Brick::reset() */ // очень опасный метод!!!! Очень много вызывается проверок, мьютексов и т.д. при остановке.
{
	LOG("Stopping brick");
	brikReset: skip; /* остановка по всем сенсорам, дисплею... */
	// возможно, отдельно стоит расписать для Keys->reset(), так как там есть lock() и внезапно, запуск может не сработать?
	// для дисплея:
	do // должно дополняться любыми INVOKE-ами, отправленными к GUIWorker-у
	 // :: перебираем все ивенты в лупе и посылаем обратно. заводим счетчик до 0. если сигналы определенного типа, не посылаем, но уменьшаем счетчик. 
	:: break; // если счетчик равняется 0
	od;
	/// @todo Temporary, we need more carefully init/deinit range sensors. (с)
	//for (RangeSensor * const rangeSensor : mRangeSensors.values()) {
	//	rangeSensor->init();
	//}
	brick_reset_return: skip;
}

inline stopScript()
{
	true; /* костыль для использования метки в начале inline, взято из официальной документации */
	stopScript_call: skip;
	if
	:: mState == stopping -> goto stopScript_return;
	:: mState == ready -> goto stopScript_return;
	:: mState == running -> skip;
	:: mState == starting -> mStateStarting: mState != starting; /* -> mState != starting означает цикл, ожидание */ // проверить, что не существует []этой метки
		/// Some script is starting right now, so we are in inconsistent state. Let it start, then stop it. (с)
	:: else -> assert(false); /* mState в программе других состояний не имеет */
	fi;
	LOG("ScriptEngineWorker: stopping script");
	mState = stopping;
	script_reset();
	/* if (mMailbox) {...} --- умышленно забиваем */
	threading_reset(); 
	// if (mDirectScriptsEngine) {...} - забиваем на runDirect пока что
	mState = ready;
	/// @todo: is it actually stopped? (c)
	LOG("ScriptEngineWorker: stopping complete");
	stopScript_return: skip;
}

inline findFreeThreadId() /* только тут меняется threadId и он равен или -1 или самому левому индексу в mThreads, который не занят */
{
	byte i = 0;
	do
	:: i < S && mThreads[i] -> i++;
	:: i < S && !mThreads[i] -> threadId = i; break;
	:: i == S -> threadId = -1; break; // возможно, если хотим использовать byte threadId, стоит отказаться от -1
	od;
}

inline startThread() /* Threading::startThread(...) --- в этом методе не важно, что за имя треда и функции нам передают, поэтому выбираем недетерминированно */
{
	true; /* костыль для использования метки в начале inline, взято из официальной документации */
	startThread_call: skip;
	short tmp;
	random(-1, S - 1, tmp);
	lock(mResetMutex, _mResetMutex, _pid);
	if
	:: mResetStarted ->
		LOG("Threading: can't start new thread due to reset"); 
		delete_engine: skip; /* delete engine; */
		unlock(mResetMutex, _mResetMutex, _pid);
		goto startThread_return;
	:: else -> skip;
	fi;
	lock(mThreadsMutex, _mThreadsMutex, _pid);
	if 
	:: (tmp != -1) && (mThreads[tmp]) -> /* если тред такой уже существует */
		LOG("ERROR: Threading: attempt to create a thread with an already occupied id");
		mErrorMessage = true;
		abort(tmp);
		unlock(mThreadsMutex, _mThreadsMutex, _pid);
		unlock(mResetMutex, _mResetMutex, _pid);
		goto startThread_return;
	:: else -> skip;
	fi;
	if
	:: (tmp != -1) && mPreventFromStart[tmp] -> /* если пытались ранее убить незапущенный тред */
		LOG("Threading: attempt to create a thread which must be killed");
		mPreventFromStart[tmp] = 0;
		mFinishedThreads[tmp] = 1;
		unlock(mThreadsMutex, _mThreadsMutex, _pid);
		unlock(mResetMutex, _mResetMutex, _pid);
		goto startThread_return;
	:: else -> skip;
	fi;
	LOG("Starting new thread ... with engine ...");
	short myThread;
	atomic {
		if
		:: threadId == -1 -> unlock(mThreadsMutex, _mThreadsMutex, _pid); unlock(mResetMutex, _mResetMutex, _pid); goto startThread_return; /* искусственно запрещаем создавать больше S тредов */
		:: threadId != -1 -> skip;
		fi;
		myThread = threadId;
		mThreads[myThread] = 1;
		abortEvaluationInvoked[myThread] = 0;
		mThreadCount++;
		assert(mThreadCount <= S); /* Изначально мы считаем, что максимальное количество запущенных потоков engineThread ограничено */
		assert(mThreadCount >= 1)
		findFreeThreadId();
	};
	mFinishedThreads[myThread] = 0;
	unlock(mThreadsMutex, _mThreadsMutex, _pid);
	run engineThread(myThread);
	/* connect(thread, SIGNAL(finished()), thread, SLOT(deleteLater())); моделируется просто выходом из ScriptThread::run(); */
	emit(engineThreadEvents[myThread], start); /* Мы переопределяли run(), поэтому отдельно расписываем thread->start() */
	/* finite cycle removed */
	LOG("Threading: started thread ... with engine ... thread object ...");
	unlock(mResetMutex, _mResetMutex, _pid);
	startThread_return: skip;
}

inline evalSystemJs() /* ScriptEngineWorker::evalSystemJs */
{
	if /* QFile::exists(systemJsPath) */
	::
		/* FileUtils::readFromFile(const QString &fileName) */
		if /* (!file.isOpen()) */
		:: throw(FailedToOpenFileException); catch ? returnControl; /* catch ? returnControl; необходим для возврата управления */
		:: skip;
		fi;
		if /* (engine->hasUncaughtException()) */
		:: skip;
		:: LOG("ERROR: system.js: Uncaught exception at line ...");
		fi;
	:: LOG("ERROR: system.js not found, path: ...");
	fi;
	/* finite cycle removed */
}

inline removePostedEvents(queue) /* очистить посланные события из очереди событий \a queue */
{
	atomic {
		mtype temp;
		do
		:: nempty(queue) -> queue ? temp;
		:: empty(queue) -> break;
		od;
	};
}
/* проверяем события \a reqSignal, которые могли быть посланы в \a reqQueue, но каким-то причинам не обработаны, а должны быть */
inline checkUnhandledSignals(reqSignal, reqQueue) // поставить во многих местах!
{
	atomic {
		mtype temp;
		do
		:: empty(reqQueue) -> break;
		:: nempty(reqQueue) ->
			reqQueue ? temp;
			if
			:: temp == reqSignal -> //assert(false); временный "фикс" в самой модели - мы как-бы фильтруем события, которые были вызываны до коннектов
			:: else -> tmpQueue ! temp;
			fi;
		od;
		do /* если дошли сюда, значит, мы проверили, что всё ок */
		:: empty(tmpQueue) -> break;
		:: nempty(tmpQueue) ->
			tmpQueue ? temp;
			reqQueue ! temp;
		od;
	};
}

proctype sensorsThread() /* на самом деле существует _много_ отдельных потоков для различных сенсоров */
{
	mtype signal;
	end: progress: do
	:: sensorsThreadEvents ? signal ->
		if
		:: signal == emptyEvent -> skip;
	    fi;
	od;
}

proctype connectionsThread() /* обслуживание клиента TrikCommunicator, обработка сообщений, потоков на самом деле _много_ */
{
	mtype signal;
	end: progress: do
	:: connectionsThreadEvents ? signal ->
		if
		:: signal == emptyEvent -> skip;
	    fi;
	od;
}

proctype engineThread(byte id) /* id остаётся одинаковым на всё время жизни треда */
{
	// byte commands = 200; /* пусть будет максимум команд в скрипте */
	chan tmpQueue = [N] of {mtype}; /* необходимый для моделирования и проверок канал */
	mtype signal;
	engineThreadEvents[id] ? signal -> /* цикла нет! (так как не запущен exec()) */
	if
	:: signal == start -> /* ScriptThread::run() */
		LOG("Started thread ScriptThread");
		evaluate_call: skip; /* mEngine->evaluate(mScript) --- скрипт внутри может вызвать новые потоки, убивать... */
		// assert(!abortEvaluationInvoked[id]); временно закомментировали, ибо в модели никак не отражается ограничение в реальной системе
		/* аборт исполнения скрипта до самого исполнения может привести к краху программы */
		/* progress в данном месте, так как может быть бесконечный цикл для автоматизированной системы */
		progress: do /* в данной модели забиваем тут на brick, gamepad, mailbox из createScriptEngine */
		:: !abortEvaluationInvoked[id] -> /* если не был вызван аборт исполнения скрипта */
			if
			::	//mThreadCount < S ->
				evalSystemJs();
				copyRecursivelyTo: skip; /* рекурсивное копирование, _знаем_, что не бесконечное */
				evalSystemJs();
				startThread(); /* параметр моделируем через недетерминизм, кол-во тредов ограничиваем сами или run()-ом */
			:: joinThread(id); /* параметр моделируем через недетерминизм */
			:: killThread(); /* параметр моделируем через недетерминизм */
			// :: sendMessage();
			// :: receiveMessage();
			:: printCommand();
			:: script_quit();
			:: script_run();
			:: script_wait(); // вообще можно проверить свойства, что в скрипте можно написать хрень, из-за которой что-то произойдет O_o
			// WARNING: можно испускать сигналы из ScriptExecutionControl.
			:: mErrorMessage = true; break; /* непредвиденная ошибка */ // в таком случае мы можем не показать важную ошибку, если она произошла в другом потоке
			:: break; /* конец скрипта */
			fi;
		:: else -> break;
		od;
		evaluate_return: skip;
		if /* mEngine->hasUncaughtException() */
		:: mErrorMessage -> LOG("Uncaught exception at line ..."); // изменили модель, добавив проверку на непустоту mErrorMessage чтоб "поправить ошибку"
		:: else ->
			if
			:: mInEventDrivenMode -> 
				atomic {
					checkUnhandledSignals(stopRunning, engineThreadEvents[id]); /* здесь вызывается необходимый коннект, проверим, что эмитов, нужных после, до этого не было */
					isAutonomousCycle[id] = true; endRun: engineThreadEvents[id] ? stopRunning; isAutonomousCycle[id] = false; /* пойдет дальше, если stopRunning был испущен */
				};
			:: else -> skip;
			fi;
		fi;
		// mEngine->deleteLater(). можно послать соответствующий сигнал. который на обработке просто поставит метку deleted. - вообще мб удаление именно стоит проверить?
		/* Threading::threadFinished(...) */
		LOG("Finishing thread ...");
		lock(mResetMutex, _mResetMutex, _pid);
		lock(mThreadsMutex, _mThreadsMutex, _pid);
		LOG("Thread ... has finished, thread object ...");
		atomic {
			mThreads[id] = 0; 
			findFreeThreadId();
			removePostedEvents(engineThreadEvents[id]);
			// assert(empty(engineThreadEvents[id])); 
			// NOTE: это ведь плохо, если перед удалением у нас висят какие-то ивента в ивентлупе?...
			// но, возможно, нет. так как они мб не обрабатываются. тогда нужно тут очищать очередь. (это сейчас реализовано)
			mThreadCount--;
		};
		mFinishedThreads[id] = 1; // FIXME: тут если в цикле создаются треды и тут же удаляются?
		unlock(mThreadsMutex, _mThreadsMutex, _pid);
		unlock(mResetMutex, _mResetMutex, _pid);
		if /* !mErrorMessage.isEmpty() */
		:: mErrorMessage -> threading_reset();
		:: else -> skip;
		fi;
		LOG("Ended evaluation, thread ...");
		goto exit; /* испускается finished(), вызывается удаление, а остальные сигналы не обрабатываются */
	:: signal == stopRunning ->
		assert(false); /* не должен быть сигнал stopRunning до старта */
	fi;
	exit: skip;
	//>>>?assert(empty(engineThreadEvents[id])); /* логично, если "лишних" сигналов не будет */
}

proctype scriptWorkerThread()
{
	mtype signal;
	end: progress: do /* end, так как mWorkerThread удаляется при закрытии всей программы */
	:: scriptWorkerThreadEvents ? signal ->
		if 
		:: signal == INVOKEdoRun ->
			// assert(!mInEventDrivenMode); /* mInEventDrivenMode должен быть false для нового скрипта! аналогично можно проверить с помощью LTL для всех переменных */ // временный фикс
			doRunInvoked: mErrorMessage = false;
			clear(mFinishedThreads, S);
			clear(mPreventFromStart, S);
			timerTimeout = false; /* не забываем скинуть в начальное состояние все флаги в модели на момент исполнения */
			loopStopWaiting = false; /* не забываем скинуть в начальное состояние все флаги в модели на момент исполнения */
			clear(isAutonomousCycle, S); /* не забываем скинуть в начальное состояние все флаги в модели на момент исполнения */
			evalSystemJs();
			startThread();
			mState = running;
			waitForAll_call: skip;
			endLoop: mThreadCount == 0 -> /* нужно понимать, что удаляется тред, испуская finished() чуть позже изменения числа тредов и хэша */
			waitForAll_return: skip;
			LOG("ScriptEngineWorker: evaluation ended with message: empty or error");
			completedEmitted: emit(GUIThreadEvents, completed); /* также данный сигнал посылвает уведомление на виджет, что мы смоделируем косвенно в GUIThread */
		:: signal == quitSignal -> /* ScriptEngineWorker::onScriptRequestingToQuit() */
			if /* весьма странный if, но всё же в реальной системе он есть */
			:: !mInEventDrivenMode -> mInEventDrivenMode = true;
			:: mInEventDrivenMode -> skip;
			fi;
			stopScript();
		fi;
	od;
}

proctype GUIThread()
{
	mtype signal;
	LOG("TrikGui started");
	mInEventDrivenMode = false;
	RunningWidget = false;
	//	run sensorsThread(); /* см. Controller */
	//	run connectionsThread(); /* см. Controller */
	// подумать, что делать с удалением через signal finished
	// тут достаточно коннектов в конструкторе, которые стоит включить
	// возможно, что-то по коннектам стоит глянуть в backgroundWidget и Controller
	LOG("Starting TrikScriptRunner worker thread");
	atomic {
		run scriptWorkerThread();
		mResetStarted = false; /* инициализируется в конструкторе */
		mState = ready;	/* инициализируется в конструкторе */
	};
	end: progress: do /* end и progress - так как считаем, что программа всегда работает и не выключается */
	:: GUIThreadEvents ? signal -> /* расписываем ВСЕ возможные сигналы для _КАЖДОГО_ потока */
		if
		:: signal == runScript -> 
			/* TrikScriptRunner::run */
			LOG("TrikScriptRunner: new script");
			/* вызывается mScriptEngineWorker->stopScript() */
			stopScript();
			/* startScriptEvaluation */
			LOG("ScriptEngineWorker: starting script");
			mState = starting;
			/* emit startedScript(mScriptId); --- выпускаем, так как он не должен влиять на работу модели, однако важно, что он вызывает RunningWidget: */
			atomic {
				RunningWidget = true;
				showRunningWidget: skip;
			};
			atomic {
				threadId = 0; 
				clear(abortEvaluationInvoked, S);
				emit(scriptWorkerThreadEvents, INVOKEdoRun);
			};
		:: signal == completed ->
			if
			:: !mErrorMessage -> 
				atomic {
					RunningWidget = false;
					hideRunningWidgetSignal: skip; /* queuedconnection для completed значит, что мы не сразу увидим после завершения скрипта нужное нам окно */
				};
			:: mErrorMessage -> sendMessages: skip; showErrorSignal: skip; /* по всем открытым соединениям вещается об ошибке */
			fi;
			brick_reset();
		:: signal == abortScript ->
			stopScript();
			LOG("Stopping robot");
			brick_reset();
	    fi;
	od;
}

proctype User() /* процесс, который моделирует возможные вызовы методов в trikScriptRunner */
{
	/* Из устройства реальной системы понятно, что вызовы могут происходить только через очередь событий (или нажатие на кнопку или сигнал с компа) */
	if
	:: emit(GUIThreadEvents, runScript);
	:: emit(GUIThreadEvents, abortScript);
	fi;
	if
	:: emit(GUIThreadEvents, runScript);
	:: emit(GUIThreadEvents, abortScript);
	fi;
//	if // дополнительно - если хватит ресурсов компьютера проверить
//	:: emit(GUIThreadEvents, runScript); // проверить, все ли необходимые дефолтные значения возвращатся при перезапуске
//	:: emit(GUIThreadEvents, abortScript);
//	fi;
}

proctype ExceptionHandler() /* процесс, который моделирует обработку исключений */
/* второй способ моделирования --- переходить по меткам goto внутри proctype */
{
	end: progress: do
	::
		if
		:: catch ? FailedToOpenFileException ->
			// assert(false); меняем модель, сейчас как-будто обработка есть.
			catch ! returnControl; /* необходимо для возврата управления в нужную точку программы */
		fi;
	od;
}

proctype Timer()
{
	timerTimeout = true;
}

init
{
	run ExceptionHandler();
	run GUIThread();
	run User();
}