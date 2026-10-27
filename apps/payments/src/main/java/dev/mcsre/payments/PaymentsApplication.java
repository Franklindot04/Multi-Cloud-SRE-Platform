package dev.mcsre.payments;

import dev.mcsre.payments.data.MigrateCommand;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

/** Payment authorization simulation. No real payment network, card data or money is involved. */
@SpringBootApplication
public class PaymentsApplication {

    public static void main(String[] args) {
        if (args.length > 0 && args[0].equals("migrate")) {
            System.exit(MigrateCommand.run(System::getenv, System.out));
        }
        SpringApplication.run(PaymentsApplication.class, args);
    }
}
