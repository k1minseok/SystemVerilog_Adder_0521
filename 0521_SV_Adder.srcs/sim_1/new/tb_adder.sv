`timescale 1ns / 1ps

interface adder_intf;  //HW 신호 묶음(물리적 신호)
    logic       clk;
    logic       reset;
    logic       valid;
    logic [3:0] a;
    logic [3:0] b;

    logic [3:0] sum;
    logic       carry;
endinterface


class transaction;  // test를 위한 data 묶음
    rand logic [3:0] a;
    rand logic [3:0] b;
    logic [3:0] sum;
    logic carry;
    // rand logic valid;

    task display(string name);
        $display("[%s] a:%d, b:%d, carry:%d, sum:%d", name, a, b, carry, sum);
    endtask

endclass


class generator;  // 입력 data 생성
    transaction tr;  // transaction class 핸들러 선언

    // generator에서 만든 값(transaction)을 mailbox 공유 메모리에 저장하겠다.
    mailbox #(transaction) gen2drv_mbox_gen;

    event genNextEvent_gen;

    function new();  // 실체화 해주는 함수
        tr = new();  // transaction tr 실체화(메모리 공간 할당)
    endfunction

    task run();  // 랜덤 값 만들고 그 값을 display
        repeat (1000) begin
            assert (tr.randomize())  // transaction generate(데이터 랜덤 변수 대입)
            else $error("tr.randomize() error!");
            // $error : display보다 강력한 출력

            // mailbox 공유 메모리에 tr 핸들러의 값을 넣겠다.
            gen2drv_mbox_gen.put(tr);
            tr.display("GEN");
            //wait(genNextEvent1.triggered);   // 이벤트 트리거 될 때까지 대기
            @(genNextEvent_gen);
        end
    endtask

endclass


class driver;  // data -> HW 신호 변경
    virtual adder_intf drv_adder_intf;
    /*
     * 가상 인터페이스 (HW적으로 인터페이스 생성 안됨)
     * 실제 인터페이스는 test_bench module에서 생성
     */

    mailbox #(transaction) gen2drv_mbox_drv;
    transaction trans;
    // new()를 안해줬기 때문에 메모리에 공간 할당은 하지 않음
    // mailbox 공유 메모리에 접근하기 위한 transaction 핸들러

    // event genNextEvent_drv;
    event monNextEvent_drv;

    function new(virtual adder_intf adder_if2);
        this.drv_adder_intf = adder_if2;
    endfunction

    task reset();
        drv_adder_intf.a     <= 0;
        drv_adder_intf.b     <= 0;
        drv_adder_intf.valid <= 1'b0;
        drv_adder_intf.reset <= 1'b1;  // 5 클럭동안 reset High
        repeat (5) @(drv_adder_intf.clk);
        drv_adder_intf.reset <= 1'b0;
    endtask

    task run();
        forever begin
            // generator에서 생성된 transaction 값을 interface로 넘겨야함
            gen2drv_mbox_drv.get(trans);
            // mailbox 공유메모리의 값을 가져옴
            // blocking code -> 값이 들어올때까지 대기

            drv_adder_intf.a     <= trans.a;
            drv_adder_intf.b     <= trans.b;
            drv_adder_intf.valid <= 1'b1;
            trans.display("DRV");
            @(posedge drv_adder_intf.clk);  // clk rising edge 대기
            drv_adder_intf.valid <= 1'b0;
            @(posedge drv_adder_intf.clk);
            ->monNextEvent_drv;
            //->genNextEvent_drv;  // 이벤트 트리거링
        end
    endtask

endclass


class monitor;  // DUT(HW) 출력 신호를 Transaction으로 변경
    virtual adder_intf adder_intf_mon;
    mailbox #(transaction) mon2scb_mbox_mon;    // scoreboard와 사용하기 위한 mailbox
    transaction trans;
    event monNextEvent_mon;

    function new(virtual adder_intf adder_if2);
        this.adder_intf_mon = adder_if2;
        trans = new();      // gen, drv에서 사용하는 transaction과 달라서 monitor에서 실체화
    endfunction

    task run();
        forever begin
            @(monNextEvent_mon);  // driver 이벤트 트리거 되면 실행
            trans.a     = adder_intf_mon.a;
            trans.b     = adder_intf_mon.b;
            trans.sum   = adder_intf_mon.sum;
            trans.carry = adder_intf_mon.carry;
            mon2scb_mbox_mon.put(trans);
            trans.display("MON");
        end
    endtask

endclass


class scoreboard;  // SW 값과 HW 값 비교
    mailbox #(transaction) mon2scb_mbox_sb;
    transaction trans;
    event genNextEvent_sb;

    int total_cnt, pass_cnt, fail_cnt;

    function new();
        total_cnt = 0;
        pass_cnt  = 0;
        fail_cnt  = 0;
    endfunction

    task run();
        forever begin
            mon2scb_mbox_sb.get(trans);
            trans.display("SCB");
            // (trans.a + trans.b) <- reference model, golden  reference
            if ((trans.a + trans.b) == {trans.carry, trans.sum}) begin
                $display(" ---> PASS ! %d + %d = %d", trans.a, trans.b, {
                         trans.carry, trans.sum});
                pass_cnt++;
            end else begin
                $display(" ---> FAIL ! %d + %d = %d", trans.a, trans.b, {
                         trans.carry, trans.sum});
                fail_cnt++;
            end
            total_cnt++;
            ->genNextEvent_sb;
        end
    endtask
endclass


module tb_adder ();

    adder_intf adder_intface ();  // interface 실체화
    generator gen;      // 인스턴스 선언
    driver drv;
    monitor mon;
    scoreboard scb;

    event genNextEvent;
    event monNextEvent;

    mailbox #(transaction) gen2drv_mbox;
    mailbox #(transaction) mon2scb_mbox;

    adder dut (
        .clk(adder_intface.clk),  // adder 인터페이스의 멤벼변수 접근
        .reset(adder_intface.reset),
        .valid(adder_intface.valid),
        .a(adder_intface.a),
        .b(adder_intface.b),

        .sum  (adder_intface.sum),
        .carry(adder_intface.carry)
    );

    always #5 adder_intface.clk = ~adder_intface.clk;

    initial begin
        adder_intface.clk   = 1'b0;
        adder_intface.reset = 1'b1;
    end

    initial begin
        gen2drv_mbox = new();  // mailbox 실체화(생성자)
        mon2scb_mbox = new();  // mailbox의 생성자는 systme verilog에 내장되어 있음
        // () 값이 비어있으면 mailbox 크기 무한대

        gen = new();    // gen 객체가 속한 class(generator)의 생성자 호출
        drv = new(adder_intface);  // 실체화된 adder_if를 driver 가상 인터페이스에 넣음
        mon = new(adder_intface);
        scb = new();
        // 클래스 내에 new() 생성자가 없을 경우 기본 생성자 -> 메모리에 공간 할당

        gen.genNextEvent_gen = genNextEvent;
        scb.genNextEvent_sb = genNextEvent;  // gen event와 drv event 연결
        mon.monNextEvent_mon = monNextEvent;
        drv.monNextEvent_drv = monNextEvent;

        gen.gen2drv_mbox_gen = gen2drv_mbox;
        drv.gen2drv_mbox_drv = gen2drv_mbox;    // driver의 mailbox에 실체화된 mailbox 레퍼런스 값 넣음
        mon.mon2scb_mbox_mon = mon2scb_mbox;
        scb.mon2scb_mbox_sb = mon2scb_mbox;

        drv.reset();

        fork  // fork 안의 내용 동시 실행
            gen.run();  // generator의 run task 실행
            drv.run();
            mon.run();
            scb.run();
        join_any

        $display("==========================");
        $display("==     Final Report    ==");
        $display("==========================");
        $display("Total Test : %d", scb.total_cnt);
        $display("Pass Count : %d", scb.pass_cnt);
        $display("Fail Count : %d", scb.fail_cnt);
        $display("==========================");
        $display("== test bench is finished! ==");
        $display("==========================");
        #10 $finish;
    end

endmodule
